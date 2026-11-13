import ApelinCore
import ApelinProtocol
import UIKit

/// Available release artifacts, newest first, each Built, Shared or
/// Published and identified by its build time. Explicit selection permits
/// one artifact per architecture; publishing and sharing use those exact
/// files. Below them, choose build targets and review distribution advice.
/// Same-version history never asks for confirmation before rebuilding;
/// other warnings do, while errors block Build. A workspace's own script
/// produces the package, which is checked after the build. A project with
/// no build description or script offers no build targets.
@MainActor
final class ProjectDistributionController: TableController {
    private enum Section: Hashable {
        case project, packages, target, readiness
    }

    private enum Row: Hashable {
        case project, package(String), publish, target(BuildBootstrap), checking, ready, blocker(Int), issue(Int), prepare, unavailable
    }

    private struct RowContent: Equatable {
        var row: Row
        var text: String?
        var secondaryText: String?
        /// What VoiceOver reads for the row when it is not the two texts.
        var spokenText: String?
        var spokenValue: String?
        var selected = false
        var enabled = true
    }

    private let projectName: String
    /// Asks the project's conversation to prepare the package; nil where
    /// the page was not opened from one.
    private let onPrepare: ((String) -> Void)?
    @objc private dynamic var displayName: String?
    private var selectedTargets: Set<BuildBootstrap> = [.roothide]
    private var issuesByTarget: [BuildBootstrap: [ProjectDiagnostic]] = [:]
    /// Nil until the manifest is read; one that cannot build takes the
    /// targets away.
    private var method: ProjectBuildMethod?
    /// The check's errors: the build would stop at them.
    private var blockers: [ProjectDiagnostic] = []
    private var issues: [ProjectDiagnostic] = []
    @objc private dynamic var checking = true
    @objc private dynamic var showsChecking = false
    @objc private dynamic var hasCheckResult = false
    private var loadingDelay: Task<Void, Never>?
    @objc private dynamic var checkFailure: String?
    private var check: Task<Void, Never>?
    /// Available release builds, newest first; selection names artifacts.
    private var packages: [DistributionPackage] = []
    @objc private dynamic var selectedPackages: Set<String> = []
    private var packageReader: Task<Void, Never>?
    private var isRemovingPackages = false
    private var removalSelection: Set<String> = []
    private var buildButton: UIBarButtonItem!
    private var moreButton: UIBarButtonItem!
    private var removalButton: UIBarButtonItem!
    /// While a package is read back to be shared or published.
    @objc private dynamic var isPreparingPackage = false
    @objc private dynamic var hasAppeared = false
    private var dataSource: TableDataSource<Section, Row, RowContent>!

    init(projectName: String, onPrepare: ((String) -> Void)? = nil) {
        self.projectName = projectName
        self.onPrepare = onPrepare
        super.init(style: .insetGrouped)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("Use init(projectName:onPrepare:)")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = String(localized: "Distribute Project")
        buildButton = UIBarButtonItem(
            title: String(localized: "Build"),
            primaryAction: UIAction { [weak self] _ in self?.build() },
        )
        moreButton = UIBarButtonItem(image: UIImage(systemName: "ellipsis.circle"), menu: UIMenu(children: [
            UIAction(title: String(localized: "Batch Remove…"), image: UIImage(systemName: "trash"), attributes: .destructive) { [weak self] _ in
                self?.setRemovalMode(true)
            },
        ]))
        moreButton.accessibilityLabel = String(localized: "More")
        removalButton = UIBarButtonItem(title: nil, primaryAction: UIAction { [weak self] _ in self?.confirmRemoval() })
        removalButton.tintColor = .systemRed
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "Distribution")
        dataSource = TableDataSource(
            tableView: tableView,
            identifier: { $0.row },
        ) { [weak self] tableView, indexPath, content in
            let cell = tableView.dequeueReusableCell(withIdentifier: "Distribution", for: indexPath)
            self?.configure(cell, value: content)
            return cell
        }
        dataSource.allowsEditing = true
        dataSource.headerTitle = { section in
            switch section {
            case .project: nil
            case .packages: String(localized: "Packages")
            case .target: String(localized: "Target")
            case .readiness: String(localized: "Before Distributing")
            }
        }
        dataSource.footerTitle = { [weak self] section in
            switch section {
            case .packages:
                self?.isRemovingPackages == true
                    ? String(localized: "Select the local packages to remove.")
                    : String(localized: "Publish the selected packages to your package repository together, or share one. Each is the file its build made, unchanged.")
            case .target: String(localized: "Choose one or both targets, then tap “Build”. Selected targets build in order: roothide, then rootless.")
            case .readiness:
                self?.blockers.isEmpty == false
                    ? String(localized: "Fix these before building.")
                    : self?.issues.isEmpty == false
                    ? String(localized: "These are suggestions. You can still build the package.")
                    : nil
            case .project: nil
            }
        }
        updateRows()
        refreshCheck()
        Task { [weak self] in
            guard let self else { return }
            displayName = await (try? ProjectSummary.load())?.first { $0.name == self.projectName }?.displayTitle
            updateRows()
        }
    }

    /// A project changed while the build page was open is checked again
    /// on the way back, and its packages are read again each time: a build
    /// or a publish may have changed them.
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        updateRemovalControls()
        if hasAppeared {
            refreshCheck()
        }
        if !isPreparingPackage { refreshPackages() }
        hasAppeared = true
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        if isRemovingPackages { navigationController?.setToolbarHidden(true, animated: animated) }
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: !UIAccessibility.isReduceMotionEnabled)
        if isRemovingPackages {
            guard !isPreparingPackage, case let .package(id) = dataSource.itemIdentifier(for: indexPath) else { return }
            if removalSelection.remove(id) == nil { removalSelection.insert(id) }
            updateRows()
            return
        }
        switch dataSource.itemIdentifier(for: indexPath) {
        case let .package(artifactID):
            guard !isPreparingPackage, let package = packages.first(where: { $0.artifactID == artifactID }) else { return }
            if selectedPackages.remove(artifactID) == nil {
                let sameArchitecture = Set(packages.filter { $0.architecture == package.architecture }.map(\.artifactID))
                selectedPackages.subtract(sameArchitecture)
                selectedPackages.insert(artifactID)
            }
            updateRows()
        case .publish:
            publish()
        case let .target(target):
            if selectedTargets.remove(target) == nil {
                selectedTargets.insert(target)
            }
            refreshCheck()
        case .prepare:
            prepare()
        default:
            break
        }
    }

    override func tableView(_: UITableView, editingStyleForRowAt indexPath: IndexPath) -> UITableViewCell.EditingStyle {
        guard !isPreparingPackage, !isRemovingPackages,
              case .package? = dataSource.itemIdentifier(for: indexPath) else { return .none }
        return .delete
    }

    override func tableView(
        _: UITableView,
        trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath,
    ) -> UISwipeActionsConfiguration? {
        guard !isPreparingPackage, !isRemovingPackages,
              case let .package(artifactID) = dataSource.itemIdentifier(for: indexPath),
              let package = packages.first(where: { $0.artifactID == artifactID }) else { return nil }
        let remove = UIContextualAction(style: .destructive, title: String(localized: "Remove")) { [weak self] _, _, complete in
            guard let self, !isPreparingPackage else { complete(false); return }
            isPreparingPackage = true
            packageReader?.cancel()
            updateRows()
            Task { [weak self] in
                guard let self else { complete(false); return }
                do {
                    try await DistributionPackages.remove(package)
                    selectedPackages.remove(artifactID)
                    packages.removeAll { $0.artifactID == artifactID }
                    complete(true)
                } catch {
                    complete(false)
                    presentNotice(title: "Unable to Remove Package", message: error.readableMessage)
                }
                isPreparingPackage = false
                updateRows()
                refreshPackages()
            }
        }
        remove.image = UIImage(systemName: "trash")
        let configuration = UISwipeActionsConfiguration(actions: [remove])
        configuration.performsFirstActionWithFullSwipe = false
        return configuration
    }

    // MARK: - Rows

    private func configure(_ cell: UITableViewCell, value: RowContent) {
        var content: UIListContentConfiguration = switch value.row {
        case .project: .valueCell()
        case .ready, .issue: .explanatoryCell()
        default: .stackedValueCell()
        }
        content.text = value.text
        content.secondaryText = value.secondaryText
        content.secondaryTextProperties.color = .secondaryLabel
        cell.accessoryType = .none
        cell.accessoryView = nil
        cell.selectionStyle = .none
        cell.isAccessibilityElement = true
        cell.accessibilityTraits = .staticText
        cell.accessibilityCustomActions = nil
        switch value.row {
        case .project:
            break
        case let .package(artifactID):
            content.secondaryTextProperties.numberOfLines = 0
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = .right
            content.secondaryAttributedText = NSAttributedString(
                string: value.secondaryText ?? "",
                attributes: [.paragraphStyle: paragraph],
            )
            content.image = UIImage(systemName: value.selected ? "checkmark.circle.fill" : "circle")
            content.imageProperties.tintColor = value.selected ? .tintColor : .tertiaryLabel
            cell.selectionStyle = .default
            cell.accessibilityTraits = value.selected ? [.button, .selected] : .button
            if !isRemovingPackages {
                cell.accessoryView = shareButton(for: artifactID)
                // the row is the element, so its Share button is reached as an action
                cell.accessibilityCustomActions = [
                    UIAccessibilityCustomAction(name: String(localized: "Share Package")) { [weak self, weak cell] _ in
                        guard let self, let cell else { return false }
                        share(artifactID, from: cell)
                        return true
                    },
                ]
            }
        case .publish:
            content.textProperties.color = value.enabled ? .tintColor : .tertiaryLabel
            cell.selectionStyle = value.enabled ? .default : .none
            cell.accessibilityTraits = value.enabled ? .button : [.button, .notEnabled]
        case .target:
            cell.accessoryType = value.selected ? .checkmark : .none
            cell.selectionStyle = .default
            cell.accessibilityTraits = value.selected ? [.button, .selected] : .button
        case .checking:
            let spinner = UIActivityIndicatorView(style: .medium)
            spinner.startAnimating()
            cell.accessoryView = spinner
        case .ready:
            content.image = UIImage(systemName: "checkmark.seal.fill")
            content.imageProperties.tintColor = .systemGreen
        case .blocker:
            content.image = UIImage(systemName: "xmark.octagon.fill")
            content.imageProperties.tintColor = .systemRed
            content.textProperties.numberOfLines = 0
        case .issue:
            content.image = UIImage(systemName: "exclamationmark.triangle.fill")
            content.imageProperties.tintColor = .systemOrange
            content.textProperties.numberOfLines = 0
            content.secondaryTextProperties.numberOfLines = 0
        case .prepare:
            content.textProperties.color = .tintColor
            cell.selectionStyle = .default
            cell.accessibilityTraits = .button
        case .unavailable:
            content.textProperties.numberOfLines = 0
            content.textProperties.color = .secondaryLabel
        }
        cell.contentConfiguration = content
        cell.accessibilityLabel = value.spokenText
            ?? [value.text, value.secondaryText].compactMap(\.self).joined(separator: ", ")
        cell.accessibilityValue = value.spokenValue
    }

    /// The Share button at a package row's trailing edge.
    private func shareButton(for artifactID: String) -> UIButton {
        let button = UIButton(type: .system)
        button.setImage(UIImage(systemName: "square.and.arrow.up"), for: .normal)
        button.accessibilityLabel = String(localized: "Share Package")
        button.sizeToFit()
        button.addAction(UIAction { [weak self, weak button] _ in
            guard let self, let button else { return }
            share(artifactID, from: button)
        }, for: .touchUpInside)
        return button
    }

    @objc private dynamic func updateRows() {
        let canBuild = method?.canBuild ?? true
        var readiness: [RowContent]
        if let blocker = method?.blocker {
            readiness = [RowContent(row: .unavailable, text: blocker)]
        } else if showsChecking {
            readiness = [RowContent(row: .checking, text: String(localized: "Checking…"))]
        } else if !hasCheckResult {
            readiness = []
        } else if let checkFailure {
            readiness = [RowContent(row: .unavailable, text: checkFailure)]
        } else if blockers.isEmpty, issues.isEmpty {
            readiness = [RowContent(
                row: .ready,
                text: String(localized: "Ready to distribute"),
                secondaryText: method == .script
                    ? String(localized: "The package is checked after the build script writes it.")
                    : nil,
            )]
        } else {
            readiness = blockers.indices.map { index in
                RowContent(row: .blocker(index), text: blockers[index].message)
            }
            let labelledIssues = BuildBootstrap.allCases.flatMap { target in
                (issuesByTarget[target] ?? []).map { (target, $0) }
            }
            readiness += labelledIssues.indices.map { index in
                let (target, issue) = labelledIssues[index]
                let advice = DistributionAdvice.advice(for: issue)
                return RowContent(
                    row: .issue(index),
                    text: DistributionAdvice.title(of: issue),
                    secondaryText: selectedTargets.count > 1
                        ? [target.rawValue, advice].compactMap(\.self).joined(separator: ": ")
                        : advice,
                )
            }
            if onPrepare != nil {
                readiness.append(RowContent(row: .prepare, text: String(localized: "Ask Agent to Prepare")))
            }
        }
        var sections: [(Section, [RowContent])] = [
            (.project, [RowContent(row: .project, text: String(localized: "Project"), secondaryText: displayName ?? projectName)]),
        ]
        let listed = packages
        if !listed.isEmpty {
            let rows = listed.map { package in
                let state = package.state.title
                let date = package.createdAt.formatted(date: .numeric, time: .standard)
                return RowContent(
                    row: .package(package.artifactID),
                    text: "\(package.bootstrap.rawValue) · \(package.version) · \(state)",
                    secondaryText: date,
                    spokenText: "\(package.bootstrap.rawValue), \(package.packageID), \(package.version), \(date)",
                    spokenValue: state,
                    selected: isRemovingPackages ? removalSelection.contains(package.artifactID) : selectedPackages.contains(package.artifactID),
                )
            }
            let canPublish = !isPreparingPackage && listed.contains { selectedPackages.contains($0.artifactID) }
            let publish = RowContent(row: .publish, text: String(localized: "Publish to Repository"), enabled: canPublish)
            sections.append((.packages, isRemovingPackages ? rows : rows + [publish]))
        }
        if canBuild, !isRemovingPackages {
            sections.append((.target, BuildBootstrap.allCases.map { target in
                RowContent(row: .target(target), text: target.rawValue, selected: selectedTargets.contains(target))
            }))
        }
        if !readiness.isEmpty, !isRemovingPackages {
            sections.append((.readiness, readiness))
        }
        dataSource.update(sections, reconfigure: true)
        buildButton.isEnabled = canBuild && blockers.isEmpty && !checking && !isPreparingPackage
            && checkFailure == nil && !selectedTargets.isEmpty
        updateRemovalControls()
    }

    private func setRemovalMode(_ enabled: Bool) {
        guard !isPreparingPackage, !enabled || !packages.isEmpty else { return }
        isRemovingPackages = enabled
        removalSelection.removeAll()
        updateRows()
    }

    private func updateRemovalControls() {
        navigationItem.hidesBackButton = isRemovingPackages
        moreButton.isEnabled = !packages.isEmpty && !isPreparingPackage
        if isRemovingPackages {
            navigationItem.leftBarButtonItem = UIBarButtonItem(
                title: String(localized: "Cancel"),
                primaryAction: UIAction { [weak self] _ in self?.setRemovalMode(false) },
            )
            let allSelected = !packages.isEmpty && removalSelection.count == packages.count
            navigationItem.rightBarButtonItems = [UIBarButtonItem(
                title: allSelected ? String(localized: "Deselect All") : String(localized: "Select All"),
                primaryAction: UIAction { [weak self] _ in
                    guard let self, !isPreparingPackage else { return }
                    removalSelection = allSelected ? [] : Set(packages.map(\.artifactID))
                    updateRows()
                },
            )]
            navigationItem.leftBarButtonItem?.isEnabled = !isPreparingPackage
            navigationItem.rightBarButtonItem?.isEnabled = !isPreparingPackage && !packages.isEmpty
            removalButton.title = String(localized: "Remove (\(removalSelection.count))")
            removalButton.isEnabled = !isPreparingPackage && !removalSelection.isEmpty
            toolbarItems = [.flexibleSpace(), removalButton, .flexibleSpace()]
        } else {
            navigationItem.leftBarButtonItem = nil
            navigationItem.rightBarButtonItems = [buildButton, moreButton]
            toolbarItems = nil
        }
        navigationController?.setToolbarHidden(!isRemovingPackages, animated: false)
    }

    private func confirmRemoval() {
        let chosen = packages.filter { removalSelection.contains($0.artifactID) }
        guard isRemovingPackages, !isPreparingPackage, !chosen.isEmpty else { return }
        presentConfirmation(
            title: "Remove \(chosen.count) Local Packages?",
            message: "These files will no longer be available to share or publish. You will need to build them again. Installed packages, repository copies, logs and debug symbols are kept.",
            confirmTitle: "Remove",
            destructive: true,
        ) { [weak self] in
            self?.removePackages(chosen)
        }
    }

    private func removePackages(_ chosen: [DistributionPackage]) {
        guard isRemovingPackages, !isPreparingPackage else { return }
        isPreparingPackage = true
        packageReader?.cancel()
        updateRows()
        Task { [weak self] in
            guard let self else { return }
            var removed: Set<String> = []
            var failures: [String] = []
            for package in chosen {
                do {
                    try await DistributionPackages.remove(package)
                    removed.insert(package.artifactID)
                } catch {
                    failures.append("\(package.bootstrap.rawValue) · \(package.version): \(error.readableMessage)")
                }
            }
            packages.removeAll { removed.contains($0.artifactID) }
            selectedPackages.subtract(removed)
            removalSelection.subtract(removed)
            isPreparingPackage = false
            if failures.isEmpty { setRemovalMode(false) }
            updateRows()
            if !failures.isEmpty {
                let summary = String(localized: "Removed \(removed.count) packages; \(failures.count) could not be removed.")
                presentNotice(title: "Unable to Remove Package", message: ([summary] + failures).joined(separator: "\n\n"))
            }
        }
    }

    // MARK: - The check

    /// The distribution check for the chosen target (any, before one is
    /// chosen); a newer one replaces a check still running.
    @objc private dynamic func refreshCheck() {
        check?.cancel()
        loadingDelay?.cancel()
        checking = true
        showsChecking = false
        updateRows()
        loadingDelay = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(500)) }
            catch { return }
            guard let self, !Task.isCancelled, checking else { return }
            showsChecking = true
            updateRows()
        }
        let targets = BuildBootstrap.allCases.filter { selectedTargets.contains($0) }
        check = Task { [weak self] in
            guard let self else { return }
            defer {
                if !Task.isCancelled {
                    loadingDelay?.cancel()
                    checking = false
                    showsChecking = false
                    hasCheckResult = true
                    updateRows()
                }
            }
            do {
                let project = try await DistributionProject.resolve(named: projectName)
                guard !Task.isCancelled else { return }
                method = project.method
                guard project.method.canBuild else {
                    blockers = []
                    issues = []
                    checkFailure = nil
                    return
                }
                var checkedBlockers: [ProjectDiagnostic] = []
                var checkedIssues: [ProjectDiagnostic] = []
                var perTarget: [BuildBootstrap: [ProjectDiagnostic]] = [:]
                for target in targets {
                    let response = try await ApelinService.app.projectCheck(
                        projectID: project.id,
                        purpose: .distribution,
                        bootstrap: target,
                    )
                    try Task.checkCancellation()
                    let errors = response.diagnostics.filter { $0.severity == .error }
                    let warnings = response.diagnostics.filter {
                        $0.code.hasPrefix("distribution.") && $0.severity != .error
                            && $0.code != DistributionAdvice.versionPackaged
                    }
                    perTarget[target] = warnings
                    checkedBlockers += errors.map { diagnostic in
                        var diagnostic = diagnostic
                        if targets.count > 1 { diagnostic.message = "\(target.rawValue): \(diagnostic.message)" }
                        return diagnostic
                    }
                    checkedIssues += warnings
                }
                checkFailure = nil
                blockers = checkedBlockers
                issues = checkedIssues
                issuesByTarget = perTarget
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                blockers = []
                issues = []
                checkFailure = error.readableMessage
            }
        }
    }

    // MARK: - Packages

    /// Available release history, and whether the linked repository holds
    /// the exact bytes of each artifact.
    @objc private dynamic func refreshPackages() {
        packageReader?.cancel()
        dataSource.beginLoad()
        packageReader = Task { [weak self] in
            guard let self else { return }
            var found: [DistributionPackage] = []
            if let project = try? await DistributionProject.resolve(named: projectName), project.method.canBuild {
                // the link needs no network; a failure leaves every package unpublished
                let linked = try? await ApelinService.app.distributionRepositoryList(repositories: false).linked
                found = await DistributionPackages.history(
                    projectID: project.id,
                    package: project.package,
                    isWorkspace: project.method == .script,
                    repository: linked,
                )
            }
            guard !Task.isCancelled else { return }
            show(found)
        }
    }

    /// Preserve explicit choices while refreshing, without selecting new
    /// artifacts on the reader's behalf. At most one per architecture.
    private func show(_ found: [DistributionPackage]) {
        var architectures: Set<String> = []
        selectedPackages = Set(found.filter { package in
            selectedPackages.contains(package.artifactID)
                && architectures.insert(package.architecture).inserted
        }.map(\.artifactID))
        packages = found
        removalSelection.formIntersection(Set(found.map(\.artifactID)))
        updateRows()
    }

    private func share(_ artifactID: String, from anchor: UIView) {
        guard let package = packages.first(where: { $0.artifactID == artifactID }),
              !isPreparingPackage, presentedViewController == nil else { return }
        isPreparingPackage = true
        Task { [weak self] in
            guard let self else { return }
            await DistributionPublishing.share(package.item, from: self, anchor: anchor) { [weak self] in
                self?.updateRows()
            }
            isPreparingPackage = false
        }
    }

    /// The selected packages, roothide's first, in one publish.
    @objc private dynamic func publish() {
        let chosen = BuildBootstrap.allCases.flatMap { target in
            packages.filter { $0.bootstrap == target && selectedPackages.contains($0.artifactID) }
        }
        guard !chosen.isEmpty, !isPreparingPackage,
              Set(chosen.map(\.architecture)).count == chosen.count else { return }
        isPreparingPackage = true
        updateRows()
        Task { [weak self] in
            guard let self else { return }
            await DistributionPublishing.publish(chosen.map(\.item), from: self)
            isPreparingPackage = false
            updateRows()
        }
    }

    // MARK: - Actions

    @objc private dynamic func build() {
        let targets = BuildBootstrap.allCases.filter { selectedTargets.contains($0) }
        guard !checking, checkFailure == nil, !targets.isEmpty, let method, method.canBuild, blockers.isEmpty else { return }
        let open = { [weak self] in
            guard let self else { return }
            navigationController?.pushViewController(
                DistributionBuildController(projectName: projectName, targets: targets, method: method),
                animated: true,
            )
        }
        // Rebuilding the same version is allowed, regardless of whether
        // its previous artifact is still available.
        let asked = targets.flatMap { target in
            (issuesByTarget[target] ?? []).filter { $0.code != DistributionAdvice.versionPackaged }
        }
        guard !asked.isEmpty else {
            open()
            return
        }
        presentConfirmation(
            title: "Build Anyway?",
            message: "Some details still need attention before other people install this package.",
            confirmTitle: "Build",
            onConfirm: open,
        )
    }

    @objc private dynamic func prepare() {
        guard !checking, let onPrepare else { return }
        let prompt = if method == .script {
            String(localized: "Prepare this workspace for distribution: run apelin_project_check_distribution and fix everything it lists, and make sure its build script writes a release package for each target when APELIN_CONFIGURATION is release, with the package’s real name, identifier, author and a new version. Then tell me what you changed. Do not build yet.")
        } else if selectedTargets.count == 1, let target = selectedTargets.first {
            String(localized: "Prepare this project for distribution to \(target.rawValue): run apelin_project_check_distribution, fix everything it lists (the package’s name, description, author and version, its identifiers, and the app’s icon if it has one), then tell me what you changed. Do not build yet.")
        } else {
            String(localized: "Prepare this project for distribution: run apelin_project_check_distribution, fix everything it lists (the package’s name, description, author and version, its identifiers, and the app’s icon if it has one), then tell me what you changed. Do not build yet.")
        }
        dismiss(animated: true) { onPrepare(prompt) }
    }
}

/// The project folder's identity, read from its own manifest after the
/// folder is resolved inside `Projects/`.
enum DistributionProject {
    /// The project's ID; throws for one with nothing to build its package
    /// from, saying what it needs.
    static func id(named name: String) async throws -> String {
        let project = try await resolve(named: name)
        if let blocker = project.method.blocker {
            throw ApelinError(.badRequest, blocker)
        }
        return project.id
    }

    /// What the distribution pages read from a project's manifest.
    struct Manifest {
        var id: String
        /// How its package is built.
        var method: ProjectBuildMethod
        /// The package its description builds, and the version; nil for a
        /// workspace, whose script decides both, and a description that
        /// names neither.
        var package: (id: String, version: String)?
    }

    static func resolve(named name: String) async throws -> Manifest {
        try await Task.detached { () throws -> Manifest in
            guard let root = DataFolder.app.project(named: name), let canonical = CanonicalPath.resolve(root.path),
                  let projects = CanonicalPath.resolve(DataFolder.app.projects.path),
                  canonical == projects + "/" + name,
                  let manifest = CanonicalPath.resolve(root.appendingPathComponent("apelin-project.json").path),
                  manifest == canonical + "/apelin-project.json"
            else {
                throw ApelinError(.notFound, String(localized: "This project is no longer available."))
            }
            let value = try JSONCoding.decode(JSONValue.self, from: Data(contentsOf: URL(fileURLWithPath: manifest)))
            guard let id = value["projectID"]?.stringValue else {
                throw ApelinError(.notFound, String(localized: "This project is no longer available."))
            }
            let method = ProjectBuildMethod(manifest: value)
            var package: (id: String, version: String)?
            if method == .description, let packageID = value["package"]?["id"]?.stringValue,
               let version = value["package"]?["version"]?.stringValue
            {
                package = (packageID, version)
            }
            return Manifest(id: id, method: method, package: package)
        }.value
    }
}
