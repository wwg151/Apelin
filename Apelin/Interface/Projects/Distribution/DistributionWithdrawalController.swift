import ApelinCore
import ApelinProtocol
import UIKit

/// Remote packages, independent of local build history.
@MainActor
final class DistributionWithdrawalController: TableController {
    private enum Row: Hashable {
        case message(String)
        case package(DistributionRepositoryPackage, Bool)
    }

    private var snapshot: DistributionPackagesResponse?
    private var selected: Set<DistributionRepositoryPackage> = []
    private var loading = false
    private var loader: Task<Void, Never>?
    private var withdrawButton: UIBarButtonItem!
    private lazy var dataSource = TableDataSource<Int, Row, Row>(tableView: tableView, identifier: { $0 }) { _, _, row in
        let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
        var content = UIListContentConfiguration.stackedValueCell()
        cell.isAccessibilityElement = true
        switch row {
        case let .message(text):
            content.text = text
            content.textProperties.color = .secondaryLabel
            cell.selectionStyle = .none
        case let .package(package, selected):
            content.text = String(package.path.dropFirst(5))
            content.textProperties.numberOfLines = 0
            content.image = UIImage(systemName: selected ? "checkmark.circle.fill" : "circle")
            cell.accessibilityTraits = selected ? [.button, .selected] : .button
        }
        cell.contentConfiguration = content
        cell.accessibilityLabel = content.text
        return cell
    }

    init() { super.init(style: .insetGrouped) }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("Use init()") }

    deinit { loader?.cancel() }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = String(localized: "Withdraw from Repository…")
        navigationItem.largeTitleDisplayMode = .never
        withdrawButton = UIBarButtonItem(title: String(localized: "Withdraw"), primaryAction: UIAction { [weak self] _ in self?.confirm() })
        withdrawButton.tintColor = .systemRed
        refreshControl = UIRefreshControl()
        refreshControl?.addAction(UIAction { [weak self] _ in self?.load() }, for: .valueChanged)
        dataSource.footerTitle = { [weak self] _ in
            guard let repository = self?.snapshot?.repository else { return nil }
            return repository.fullName + "\n" + String(localized: "Select packages to withdraw. Local builds and installed packages are kept. The source updates after GitHub Actions finishes.")
        }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.setToolbarHidden(false, animated: animated)
        load()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        navigationController?.setToolbarHidden(true, animated: animated)
    }

    private func load() {
        loader?.cancel()
        loading = true
        selected.removeAll()
        snapshot = nil
        dataSource.update([(0, [.message(String(localized: "Loading…"))])])
        updateControls()
        loader = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await ApelinService.app.distributionPackages()
                guard !Task.isCancelled else { return }
                snapshot = result
                loading = false
                show()
            } catch {
                guard !Task.isCancelled else { return }
                loading = false
                dataSource.update([(0, [.message(error.readableMessage)])])
                updateControls()
            }
            refreshControl?.endRefreshing()
        }
    }

    private func show() {
        let packages = snapshot?.packages ?? []
        let rows: [Row] = packages.isEmpty
            ? [.message(String(localized: "No Published Packages"))]
            : packages.map { .package($0, selected.contains($0)) }
        dataSource.update([(0, rows)])
        updateControls()
    }

    private func updateControls() {
        let packages = snapshot?.packages ?? []
        let all = !packages.isEmpty && selected.count == packages.count
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            title: all ? String(localized: "Deselect All") : String(localized: "Select All"),
            primaryAction: UIAction { [weak self] _ in
                guard let self, !loading else { return }
                selected = all ? [] : Set(packages)
                show()
            },
        )
        navigationItem.rightBarButtonItem?.isEnabled = !loading && !packages.isEmpty && packages.count <= 100
        withdrawButton.title = String(localized: "Withdraw") + " (\(selected.count))"
        withdrawButton.isEnabled = !loading && !selected.isEmpty && selected.count <= 100
        toolbarItems = [.flexibleSpace(), withdrawButton, .flexibleSpace()]
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard !loading, case let .package(package, _)? = dataSource.value(at: indexPath) else { return }
        if selected.remove(package) == nil, selected.count < 100 { selected.insert(package) }
        show()
    }

    private func confirm() {
        guard !loading, let snapshot, !selected.isEmpty else { return }
        let chosen = snapshot.packages.filter { selected.contains($0) }
        let message = snapshot.repository.fullName + "\n\n" + chosen.map(\.path).joined(separator: "\n") + "\n\n"
            + String(localized: "These packages will be removed from the repository in one commit. Local builds and installed packages are kept. The source updates after GitHub Actions finishes.")
        presentConfirmation(title: "Withdraw from Repository?", message: "\(message)", confirmTitle: "Withdraw", destructive: true) { [weak self] in
            self?.start(snapshot, packages: chosen)
        }
    }

    private func start(_ snapshot: DistributionPackagesResponse, packages: [DistributionRepositoryPackage]) {
        guard !loading else { return }
        loading = true
        updateControls()
        Task { [weak self] in
            guard let self else { return }
            do {
                let handle = try await ApelinService.app.distributionWithdraw(snapshot: snapshot, packages: packages)
                let page = EnvironmentTaskController(handle: handle, work: .distributionWithdraw,
                    title: String(localized: "Withdrawing Packages"), doneTitle: String(localized: "Withdrawn"))
                page.onFinish = { [weak self] in self?.load() }
                navigationController?.pushViewController(page, animated: true)
            } catch {
                presentNotice(title: "Unable to Withdraw Packages", message: error.readableMessage)
            }
            loading = false
            updateControls()
        }
    }
}
