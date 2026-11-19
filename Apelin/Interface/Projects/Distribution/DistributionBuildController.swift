import ApelinCore
import ApelinProtocol
import Then
import UIKit

/// Serial release builds for the selected distribution targets. Each
/// target keeps its result and log. Success advances automatically; failure
/// or Stop pauses for Retry or Continue. Successful artifacts can be shared
/// separately or published together through DistributionPublishing. A workspace
/// runs its own script and retains the package findings under its outcome.
@MainActor
final class DistributionBuildController: UIViewController, UITableViewDelegate {
    private enum Stage: Int {
        case preparing, compiling, running, packaging, verifying, readyToDistribute

        /// apelin-build's own stages, or a workspace's script's
        /// (`ExternalBuild`: `script`, then `verify`).
        static func stages(for method: ProjectBuildMethod) -> [Stage] {
            method == .script ? [.preparing, .running, .verifying, .readyToDistribute] : [.preparing, .compiling, .packaging, .verifying, .readyToDistribute]
        }

        var title: String {
            switch self {
            case .preparing: String(localized: "Preparing")
            case .compiling: String(localized: "Compiling")
            case .running: String(localized: "Running Build Script")
            case .packaging: String(localized: "Packaging")
            case .verifying: String(localized: "Verifying Package")
            case .readyToDistribute: String(localized: "Ready to Distribute")
            }
        }

        init(event: String) {
            switch event {
            case "check": self = .preparing
            case "script": self = .running
            case "package": self = .packaging
            case "verify": self = .verifying
            default: self = .compiling
            }
        }
    }

    private enum Section: Hashable {
        case progress, results, outcome
    }

    private enum Row: Hashable {
        case stage(Stage), installing, installed, installError, log, outcome, finding(Int), result(BuildBootstrap)
    }

    private struct RowContent: Equatable {
        var row: Row
        var text: String?
        var secondaryText: String?
        var enabled = false
        var selected = false
    }

    private struct Result {
        var state: TaskState
        var artifact: BuildArtifact?
        var outcome: String?
        var findings: [ProjectDiagnostic]
        var stage: Stage
        var logLines: [String]
        var errorLines: Set<Int>
    }

    private let projectName: String
    private let targets: [BuildBootstrap]
    private var target: BuildBootstrap
    private var results: [BuildBootstrap: Result] = [:]
    private var lastEventSeq: EventSeq = .start
    @objc private dynamic var buildFinished = false
    private var buildState: TaskState?
    private let method: ProjectBuildMethod

    private var nextTarget: BuildBootstrap? {
        targets.first { results[$0] == nil }
    }
    private var stage = Stage.preparing
    private var artifact: BuildArtifact?
    /// The build's `distribution.*` warnings about the package it wrote.
    private var findings: [ProjectDiagnostic] = []
    private var work: Task<Void, Never>?
    @objc private dynamic var outcome: String?
    private var finishedState: TaskState?
    private lazy var stepCells = Dictionary(uniqueKeysWithValues: Stage.stages(for: method).map { ($0, TaskStepCell(stage: String($0.rawValue))) })
    private var logLines: [String] = []
    private var errorLines: Set<Int> = []
    private let inlineLog = TaskLogController(lines: [])
    private let logCell = UITableViewCell(style: .default, reuseIdentifier: nil)
    @objc private dynamic lazy var tableView = FirstFillTableView(frame: .zero, style: .insetGrouped)
    @objc private dynamic lazy var installingCell = TaskStepCell(stage: "installing")
    @objc private dynamic lazy var installedCell = TaskStepCell(stage: "installed")
    private var installState: EnvironmentTaskProgress.StageState = .pending
    private var deviceTarget: BuildBootstrap?
    private var installFailure: String?
    @objc private dynamic var installing = false

    private func refreshLogs() {
        inlineLog.update(logLines, errorLines: errorLines)
        logPage?.update(logLines, errorLines: errorLines)
    }

    private func resetInlineLog() {
        errorLines = []
        inlineLog.reset(logLines)
    }

    private static let errorPattern = try! NSRegularExpression(
        pattern: #"(?im)(?:^|\s)(?:fatal\s+error|error)(?:\s+[A-Z]+\d+)?\s*:|^\s*(?:\[error\]|##\[error\]|failed:|\*\* BUILD FAILED \*\*)|^.*undefined (?:symbols|reference)|^make(?:\[\d+\])?: \*\*\*"#
    )

    private func appendLog(_ text: String, isError: Bool = false) {
        let clean = text.replacingOccurrences(of: #"\x1B\[[0-?]*[ -/]*[@-~]"#, with: "", options: .regularExpression)
        for line in clean.components(separatedBy: .newlines) {
            if isError || Self.errorPattern.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil {
                errorLines.insert(logLines.count)
            }
            logLines.append(line)
        }
        refreshLogs()
    }
    @objc private dynamic weak var logPage: TaskLogController?
    private var dataSource: TableDataSource<Section, Row, RowContent>!
    /// While the package is read back for Share Package or Publish to
    /// Repository: neither starts again until it is done.
    @objc private dynamic var isPreparingPackage = false {
        didSet {
            distributeButton.isEnabled = !isPreparingPackage
        }
    }

    /// The menus read the page as they open, so neither is rebuilt when the
    /// build ends or a package is being read back.
    @objc private dynamic lazy var distributeButton: UIBarButtonItem = .init(
        title: String(localized: "Distribute"),
        menu: UIMenu(children: [UIDeferredMenuElement.uncached { [weak self] completion in
            guard let self else { completion([]); return }
            completion(distributionActions(anchor: distributeButton))
        }]),
    ).then {
        // iOS 26's prominent style (the same value), a bold title before it
        $0.style = .done
    }

    @objc private dynamic lazy var moreButton = UIBarButtonItem(
        image: UIImage(systemName: "ellipsis"),
        menu: UIMenu(children: [UIDeferredMenuElement.uncached { [weak self] completion in
            completion(self?.moreMenuElements() ?? [])
        }]),
    ).then { $0.accessibilityLabel = String(localized: "More") }

    /// Distribute's choices once there is a package, then the log.
    @objc private dynamic func moreMenuElements() -> [UIMenuElement] {
        var elements: [UIMenuElement] = []
        if work == nil, artifact != nil || results.values.contains(where: { $0.artifact != nil }) {
            elements.append(UIMenu(options: .displayInline, children: distributionActions(anchor: moreButton)))
        }
        if work == nil, targets.count > 1, artifact == nil {
            elements.append(UIAction(title: String(localized: "Retry \(target.rawValue)"), image: UIImage(systemName: "arrow.clockwise")) { [weak self] _ in
                self?.start()
            })
        }
        if targets.count > 1 {
            for logTarget in targets {
                guard results[logTarget] != nil || logTarget == target else { continue }
                elements.append(UIAction(title: String(localized: "Build Log: \(logTarget.rawValue)"), image: UIImage(systemName: "doc.plaintext")) { [weak self] _ in
                    guard let self else { return }
                    if logTarget == target {
                        openLog()
                    } else if let result = results[logTarget] {
                        let page = TaskLogController(lines: result.logLines)
                        page.update(result.logLines, errorLines: result.errorLines)
                        page.loadViewIfNeeded()
                        page.title = logTarget.rawValue
                        navigationController?.pushViewController(page, animated: true)
                    }
                })
            }
        } else {
            elements.append(UIAction(title: String(localized: "Build Log"), image: UIImage(systemName: "doc.plaintext")) { [weak self] _ in
                self?.openLog()
            })
        }
        return elements
    }

    /// Share Package and Publish to Repository; the share sheet points at
    /// `anchor`, the item whose menu they were chosen from.
    @objc private dynamic func distributionActions(anchor: UIBarButtonItem) -> [UIMenuElement] {
        let attributes: UIMenuElement.Attributes = isPreparingPackage ? .disabled : []
        if targets.count > 1 {
            let shares: [UIMenuElement] = targets.compactMap { shareTarget in
                guard let artifact = results[shareTarget]?.artifact else { return nil }
                let shareItem = publishingItem(artifact, target: shareTarget)
                return UIAction(
                    title: String(localized: "Share Package: \(shareTarget.rawValue)"),
                    image: UIImage(systemName: "square.and.arrow.up"),
                    attributes: attributes,
                ) { [weak self, weak anchor] _ in
                    guard let self, let anchor, work == nil, !isPreparingPackage else { return }
                    isPreparingPackage = true
                    Task { [weak self] in
                        guard let self else { return }
                        await DistributionPublishing.share(shareItem, from: self, anchor: anchor)
                        isPreparingPackage = false
                    }
                }
            }
            let publish = UIAction(
                title: String(localized: "Publish to Repository"),
                image: UIImage(systemName: "shippingbox"),
                attributes: attributes,
            ) { [weak self] _ in self?.publish() }
            return shares + [publish]
        }
        return [
            UIAction(
                title: String(localized: "Share Package"),
                image: UIImage(systemName: "square.and.arrow.up"),
                attributes: attributes,
            ) { [weak self, weak anchor] _ in
                guard let anchor else { return }
                self?.sharePackage(from: anchor)
            },
            UIAction(
                title: String(localized: "Publish to Repository"),
                image: UIImage(systemName: "shippingbox"),
                attributes: attributes,
            ) { [weak self] _ in
                self?.publish()
            },
        ]
    }

    init(projectName: String, targets: [BuildBootstrap], method: ProjectBuildMethod) {
        precondition(!targets.isEmpty)
        let orderedTargets = BuildBootstrap.allCases.filter { targets.contains($0) }
        self.projectName = projectName
        self.targets = orderedTargets
        target = orderedTargets[0]
        self.method = method
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("Use init(projectName:target:method:)")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = target.rawValue
        navigationItem.largeTitleDisplayMode = .never
        view.backgroundColor = .systemGroupedBackground
        tableView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(tableView)
        NSLayoutConstraint.activate([
            tableView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        tableView.delegate = self
        tableView.selfSizingInvalidation = .enabledIncludingConstraints
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "Build")
        addChild(inlineLog)
        logCell.selectionStyle = .none
        logCell.isAccessibilityElement = false
        logCell.contentView.addSubview(inlineLog.view)
        inlineLog.view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            inlineLog.view.leadingAnchor.constraint(equalTo: logCell.contentView.leadingAnchor),
            inlineLog.view.trailingAnchor.constraint(equalTo: logCell.contentView.trailingAnchor),
            inlineLog.view.topAnchor.constraint(equalTo: logCell.contentView.topAnchor),
            inlineLog.view.bottomAnchor.constraint(equalTo: logCell.contentView.bottomAnchor),
            inlineLog.view.heightAnchor.constraint(equalToConstant: 320),
        ])
        inlineLog.didMove(toParent: self)
        dataSource = TableDataSource(
            tableView: tableView,
            identifier: { $0.row },
        ) { [weak self] tableView, indexPath, content in
            if case .log = content.row { return self?.logCell }
            if case .installing = content.row { return self?.installingCell }
            if case .installed = content.row { return self?.installedCell }
            if case let .stage(stage) = content.row {
                return self?.stepCells[stage]
            }
            let cell = tableView.dequeueReusableCell(withIdentifier: "Build", for: indexPath)
            self?.configure(cell, value: content)
            return cell
        }
        dataSource.headerTitle = { section in
            section == .progress ? String(localized: "Steps") : nil
        }
        start()
    }

    // MARK: - Rows

    private func configure(_ cell: UITableViewCell, value: RowContent) {
        var content: UIListContentConfiguration = switch value.row {
        case .finding: .explanatoryCell()
        default: .stackedValueCell()
        }
        content.text = value.text
        content.secondaryText = value.secondaryText
        content.secondaryTextProperties.color = .secondaryLabel
        cell.accessoryView = nil
        cell.accessoryType = .none
        cell.selectionStyle = .none
        cell.isAccessibilityElement = true
        cell.accessibilityTraits = .staticText
        cell.accessibilityValue = nil
        switch value.row {
        case .stage, .installing, .installed, .log:
            break
        case .installError, .outcome:
            content.textProperties.numberOfLines = 0
            content.secondaryTextProperties.numberOfLines = 0
            if value.row == .installError || finishedState == .failed || finishedState == .cancelled {
                let stopped = value.row == .outcome && finishedState == .cancelled
                content.image = UIImage(systemName: stopped ? "stop.circle.fill" : "exclamationmark.triangle.fill")
                content.imageProperties.tintColor = stopped ? .secondaryLabel : .systemRed
            }
        case .result:
            cell.selectionStyle = value.enabled ? .default : .none
            cell.accessoryType = value.enabled ? .disclosureIndicator : .none
            cell.accessibilityTraits = value.enabled ? .button : .staticText
            if value.selected { cell.accessibilityTraits.insert(.selected) }
        case .finding:
            content.image = UIImage(systemName: "exclamationmark.triangle.fill")
            content.imageProperties.tintColor = .systemOrange
            content.textProperties.numberOfLines = 0
            content.secondaryTextProperties.numberOfLines = 0
        }
        cell.contentConfiguration = content
        if case .result = value.row {
            cell.accessibilityLabel = value.text
            cell.accessibilityValue = value.secondaryText
        } else {
            cell.accessibilityLabel = [value.text, value.secondaryText].compactMap(\.self).joined(separator: ", ")
            cell.accessibilityValue = nil
        }
    }

    private func stageTitle(_ stage: Stage) -> String {
        guard targets.count > 1 else { return stage.title }
        switch stage {
        case .preparing: return String(localized: "Preparing \(target.rawValue)")
        case .compiling: return String(localized: "Compiling \(target.rawValue)")
        case .running: return String(localized: "Running Build Script for \(target.rawValue)")
        case .packaging: return String(localized: "Packaging \(target.rawValue)")
        case .verifying: return String(localized: "Verifying Package for \(target.rawValue)")
        case .readyToDistribute: return String(localized: "Ready to Distribute \(target.rawValue)")
        }
    }

    @objc dynamic func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: !UIAccessibility.isReduceMotionEnabled)
        guard work == nil, case let .result(selected) = dataSource.itemIdentifier(for: indexPath),
              let result = results[selected] else { return }
        showResult(result, for: selected)
        updateNavigation()
        updateRows()
    }

    private func showResult(_ result: Result, for selected: BuildBootstrap) {
        target = selected
        artifact = result.artifact
        outcome = result.outcome
        findings = result.findings
        finishedState = result.state
        stage = result.stage
        logLines = result.logLines
        errorLines = result.errorLines
        inlineLog.reset(logLines, errorLines: errorLines)
        logPage = nil
        title = selected.rawValue
    }

    @objc private dynamic func updateRows() {
        for item in Stage.stages(for: method) {
            let state: EnvironmentTaskProgress.StageState = if finishedState == .succeeded || item.rawValue < stage.rawValue {
                .done
            } else if item == stage {
                finishedState == nil ? .running(nil) : .failed
            } else {
                .pending
            }
            let status: String = switch state {
            case .done: String(localized: "Completed")
            case .running: String(localized: "In Progress")
            case .failed: finishedState == .cancelled ? String(localized: "Stopped") : String(localized: "Failed")
            default: finishedState == nil ? String(localized: "Waiting") : String(localized: "Not Started")
            }
            stepCells[item]?.show(state, status: status, animated: tableView.window != nil && !UIAccessibility.isReduceMotionEnabled, title: stageTitle(item))
        }
        let showInstall = target == deviceTarget && finishedState == .succeeded && artifact?.bootstrap == target.rawValue
        if showInstall { updateInstallSteps() }
        var sections: [(Section, [RowContent])] = [
            (.progress, Stage.stages(for: method).flatMap { item -> [RowContent] in
                let row = RowContent(row: .stage(item), text: item.title)
                if item == .readyToDistribute, showInstall {
                    var steps = [row, RowContent(row: .installing), RowContent(row: .installed)]
                    if let installFailure {
                        steps.append(RowContent(row: .installError, text: String(localized: "Failed"), secondaryText: installFailure))
                    }
                    return steps
                }
                return item == (method == .script ? .running : .compiling)
                    ? [row, RowContent(row: .log)] : [row]
            }),
        ]
        if targets.count > 1 {
            let summaries = targets.map { resultTarget in
                let status: String
                if resultTarget == target, work != nil {
                    status = String(localized: "In Progress")
                } else {
                    status = switch results[resultTarget]?.state {
                    case .succeeded: String(localized: "Completed")
                    case .cancelled: String(localized: "Stopped")
                    case .failed: String(localized: "Failed")
                    default: String(localized: "Waiting")
                    }
                }
                return RowContent(
                    row: .result(resultTarget),
                    text: resultTarget.rawValue,
                    secondaryText: status,
                    enabled: work == nil && results[resultTarget] != nil,
                    selected: resultTarget == target,
                )
            }
            sections.append((.results, summaries))
        }
        if let outcome {
            let title = switch finishedState {
            case .succeeded: String(localized: "Completed")
            case .cancelled: String(localized: "Stopped")
            default: String(localized: "Failed")
            }
            var rows: [RowContent] = finishedState == .succeeded ? [] : [RowContent(row: .outcome, text: title, secondaryText: EnvironmentTaskProgress.readableDetail(outcome))]
            rows += findings.indices.map { index in
                RowContent(
                    row: .finding(index),
                    text: DistributionAdvice.title(of: findings[index]),
                    secondaryText: DistributionAdvice.advice(for: findings[index]),
                )
            }
            if !rows.isEmpty {
                sections.append((.outcome, rows))
            }
        }
        dataSource.update(sections, reconfigure: true)
    }

    @objc private dynamic func updateNavigation() {
        let running = work != nil
        navigationController?.isModalInPresentation = running
        navigationItem.hidesBackButton = running
        // Once submitted, Irisin owns the installation transaction.
        if installing {
            navigationItem.rightBarButtonItems = [moreButton]
            return
        }
        let primary: UIBarButtonItem = if running {
            UIBarButtonItem(
                title: String(localized: "Stop"),
                primaryAction: UIAction { [weak self] _ in
                    guard let self, !installing else { return }
                    work?.cancel()
                },
            )
        } else if let next = nextTarget {
            UIBarButtonItem(
                title: String(localized: "Continue with \(next.rawValue)"),
                primaryAction: UIAction { [weak self] _ in
                    guard let self, work == nil else { return }
                    target = next
                    start()
                },
            )
        } else if artifact != nil {
            distributeButton
        } else {
            UIBarButtonItem(
                title: String(localized: "Retry"),
                primaryAction: UIAction { [weak self] _ in self?.start() },
            )
        }
        // the right bar's items run from the trailing edge in
        navigationItem.rightBarButtonItems = [primary, moreButton]
    }

    // MARK: - Installation

    @objc private dynamic func updateInstallSteps() {
        let status: String = switch installState {
        case let .running(fraction): fraction?.formatted(.percent.precision(.fractionLength(0))) ?? String(localized: "In Progress")
        case .done: String(localized: "Completed")
        case .failed: String(localized: "Failed")
        default: String(localized: "Waiting")
        }
        let animated = tableView.window != nil && !UIAccessibility.isReduceMotionEnabled
        installingCell.show(installState, status: status, animated: animated, title: String(localized: "Installing"))
        let completion: EnvironmentTaskProgress.StageState = switch installState {
        case .done: .done
        case .failed: .skipped
        default: .pending
        }
        installedCell.show(
            completion,
            status: completion == .done ? String(localized: "Completed") : String(localized: "Not Started"),
            animated: animated,
            title: String(localized: "Installation Complete"),
        )
    }

    private func autoInstall(_ artifact: BuildArtifact) async {
        if deviceTarget == nil {
            do {
                let hello = try await ApelinService.app.hello()
                deviceTarget = BuildBootstrap.resolve(
                    installRoot: hello.installRoot,
                    home: RoothideRoot.mobileHome(for: Bundle.main.bundlePath),
                )
            } catch {
                appendLog(error.readableMessage, isError: true)
                return
            }
        }
        guard !Task.isCancelled, target == deviceTarget, artifact.bootstrap == target.rawValue else { return }
        installing = true
        installState = .running(nil)
        updateNavigation()
        updateRows()
        defer { installing = false }
        do {
            let handle = try await ApelinService.app.installPackage(
                artifactID: artifact.artifactID,
                digest: artifact.digest,
                allowExternalReplacement: true,
            )
            try await followInstall(handle)
            installState = .done
        } catch {
            installState = .failed
            installFailure = EnvironmentTaskProgress.readableDetail(error.readableMessage)
        }
        updateRows()
    }

    private func followInstall(_ handle: TaskHandle) async throws {
        var cursor: EventSeq = .start
        var reconnects = 0
        while true {
            do {
                for try await event in ApelinService.app.events(of: handle, afterSeq: cursor) {
                    cursor = event.seq
                    reconnects = 0
                    if event.kind == "irisin", let done = event.payload?["done"]?.doubleValue,
                       let total = event.payload?["total"]?.doubleValue, total > 0, total.isFinite, done.isFinite
                    {
                        installState = .running(min(max(done / total, 0), 1))
                        updateInstallSteps()
                    }
                    guard event.kind == TaskEvent.stateKind,
                          let raw = event.payload?["state"]?.stringValue,
                          let state = TaskState(rawValue: raw), state.isTerminal else { continue }
                    if state == .succeeded { return }
                    let message = event.payload?["message"]?.stringValue
                        ?? (state == .cancelled ? String(localized: "Stopped") : String(localized: "Failed"))
                    throw ApelinError(.internal, message)
                }
                throw ApelinError(.internal, String(localized: "Unavailable"))
            } catch let error as ApelinError where reconnects < 3 && [.unavailable, .backendUnavailable, .timeout].contains(error.code) {
                reconnects += 1
                try await Task.sleep(for: .seconds(1))
            }
        }
    }

    // MARK: - The build

    @objc private dynamic func start() {
        guard work == nil else { return }
        if target == deviceTarget {
            installState = .pending
            installFailure = nil
        }
        artifact = nil
        outcome = nil
        finishedState = nil
        findings = []
        stage = .preparing
        logLines = []
        resetInlineLog()
        logPage = nil
        title = target.rawValue
        results.removeValue(forKey: target)
        work = Task { [weak self] in
            guard let self else { return }
            while true {
                do {
                    let id = try await DistributionProject.id(named: projectName)
                    try Task.checkCancellation()
                    artifact = try await build(projectID: id)
                    finishedState = .succeeded
                    stage = .readyToDistribute
                    outcome = String(localized: "The package is ready to export.")
                } catch is CancellationError {
                    artifact = nil
                    finishedState = .cancelled
                    outcome = String(localized: "Distribution stopped. You can try again.")
                } catch {
                    artifact = nil
                    finishedState = .failed
                    outcome = error.readableMessage
                    appendLog(error.readableMessage, isError: true)
                }
                if finishedState == .succeeded, let artifact, !Task.isCancelled {
                    await autoInstall(artifact)
                }
                results[target] = Result(
                    state: finishedState ?? .failed,
                    artifact: artifact,
                    outcome: outcome,
                    findings: findings,
                    stage: stage,
                    logLines: logLines,
                    errorLines: errorLines,
                )
                guard finishedState == .succeeded, !Task.isCancelled, let next = nextTarget else { break }
                target = next
                title = next.rawValue
                artifact = nil
                outcome = nil
                finishedState = nil
                findings = []
                stage = .preparing
                logLines = []
                resetInlineLog()
                logPage = nil
                updateNavigation()
                updateRows()
            }
            work = nil
            // Keep the native install result in view after both builds succeed.
            if finishedState == .succeeded, nextTarget == nil,
               let deviceTarget, deviceTarget != target,
               let result = results[deviceTarget], result.state == .succeeded
            {
                showResult(result, for: deviceTarget)
            }
            updateNavigation()
            updateRows()
            if finishedState == .succeeded {
                StarPrompt.buildsCompleted(1, from: self)
            }
        }
        updateNavigation()
        updateRows()
    }

    private func build(projectID: String) async throws -> BuildArtifact {
        lastEventSeq = .start
        buildFinished = false
        buildState = nil
        let handle = try await ApelinService.app.buildStart(
            projectID: projectID,
            configuration: .release,
            bootstrap: target,
        )
        do {
            return try await followBuild(handle)
        } catch {
            if !buildFinished {
                // Wait for the worker so queued builds cannot overlap.
                await Task.detached { @MainActor [self] in
                    while !buildFinished {
                        do {
                            try await ApelinService.app.buildCancel(taskID: handle.taskID)
                        } catch {
                            appendLog(error.readableMessage, isError: true)
                        }
                        do {
                            for try await event in ApelinService.app.events(of: handle, afterSeq: lastEventSeq) {
                                record(event)
                            }
                        } catch {
                            appendLog(error.readableMessage, isError: true)
                        }
                        if !buildFinished { try? await Task.sleep(for: .seconds(1)) }
                    }
                }.value
            }
            if buildState == .succeeded, let artifact, artifact.bootstrap == target.rawValue {
                return artifact
            }
            if Task.isCancelled { throw CancellationError() }
            throw error
        }
    }

    private func followBuild(_ handle: TaskHandle) async throws -> BuildArtifact {
        try await withTaskCancellationHandler {
            var artifact: BuildArtifact?
            var succeeded = false
            var failure: String?
            for try await event in ApelinService.app.events(of: handle) {
                try Task.checkCancellation()
                record(event)
                if event.kind == "artifact" {
                    // persisted-read: a live task event, not saved data
                    artifact = try event.payload?.decode(BuildArtifact.self)
                } else if event.kind == TaskEvent.stateKind {
                    succeeded = event.payload?["state"]?.stringValue == TaskState.succeeded.rawValue
                    failure = event.payload?["message"]?.stringValue
                }
            }
            try Task.checkCancellation()
            guard succeeded, let artifact, artifact.bootstrap == target.rawValue else {
                throw ApelinError(
                    .internal,
                    failure ?? (method == .script
                        ? String(localized: "The package could not be built. Check the build script’s log and try again.")
                        : String(localized: "The package could not be built. Check the project’s build description and try again.")),
                )
            }
            return artifact
        } onCancel: {
            Task { try? await ApelinService.app.buildCancel(taskID: handle.taskID) }
        }
    }

    /// The build's own words for the log: its stages, log lines and
    /// diagnostics, and how it ended.
    private func record(_ event: TaskEvent) {
        lastEventSeq = event.seq
        if event.kind == "artifact" {
            // persisted-read: a live task event, not saved data
            artifact = try? event.payload?.decode(BuildArtifact.self)
        } else if event.kind == "stage", let name = event.payload?["stage"]?.stringValue {
            let next = Stage(event: name)
            if next != stage {
                stage = next
                updateRows()
            }
        } else if event.kind == "diagnostic",
                  let finding = try? event.payload?.decode(ProjectDiagnostic.self),
                  finding.code.hasPrefix("distribution.")
        {
            findings.append(finding)
        }
        if event.kind == TaskEvent.stateKind,
           let state = event.payload?["state"]?.stringValue,
           [TaskState.succeeded.rawValue, TaskState.failed.rawValue, TaskState.cancelled.rawValue].contains(state)
        {
            buildState = TaskState(rawValue: state)
            buildFinished = true
        }
        let line: String? = switch event.kind {
        case "stage": event.payload?["stage"]?.stringValue.map { "▸ " + $0 }
        case "log": event.payload?["line"]?.stringValue
        case "diagnostic": event.payload?["message"]?.stringValue
        case TaskEvent.stateKind:
            [event.payload?["state"]?.stringValue, event.payload?["message"]?.stringValue]
                .compactMap(\.self).joined(separator: ": ")
        default: nil
        }
        guard let line else { return }
        let isError = (event.kind == "diagnostic" && event.payload?["severity"]?.stringValue == "error") ||
            (event.kind == TaskEvent.stateKind && event.payload?["state"]?.stringValue == TaskState.failed.rawValue)
        appendLog(line, isError: isError)
    }

    @objc private dynamic func openLog() {
        let page = TaskLogController(lines: logLines)
        page.update(logLines, errorLines: errorLines)
        if targets.count > 1 {
            page.loadViewIfNeeded()
            page.title = target.rawValue
        }
        logPage = page
        navigationController?.pushViewController(page, animated: true)
    }

    /// The package this build made, as sharing and publishing take it.
    private var item: DistributionPublishing.Item? {
        guard let artifact, artifact.bootstrap == target.rawValue else { return nil }
        return publishingItem(artifact, target: target)
    }

    private func publishingItem(_ artifact: BuildArtifact, target: BuildBootstrap) -> DistributionPublishing.Item {
        DistributionPublishing.Item(
            path: artifact.path,
            digest: artifact.digest,
            packageID: artifact.packageID,
            version: artifact.version,
            bootstrap: target,
        )
    }

    @objc private dynamic func sharePackage(from anchor: UIBarButtonItem) {
        guard let item, work == nil, !isPreparingPackage else { return }
        isPreparingPackage = true
        Task { [weak self] in
            guard let self else { return }
            await DistributionPublishing.share(item, from: self, anchor: anchor)
            isPreparingPackage = false
        }
    }

    @objc private dynamic func publish() {
        let items: [DistributionPublishing.Item] = targets.count == 1 ? [item].compactMap { $0 } : targets.compactMap { publishTarget in
            guard let artifact = results[publishTarget]?.artifact else { return nil }
            return publishingItem(artifact, target: publishTarget)
        }
        guard !items.isEmpty, work == nil, !isPreparingPackage else { return }
        isPreparingPackage = true
        Task { [weak self] in
            guard let self else { return }
            await DistributionPublishing.publish(items, from: self)
            isPreparingPackage = false
        }
    }
}
