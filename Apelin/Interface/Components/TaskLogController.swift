import SnapKit
import Then
import UIKit

/// Every line a task said, in order: the page behind a task's menu, for
/// whoever wants the whole account. Irisin's operation log: a number and a
/// monospaced line each, following the end while the task runs and reading
/// the same once it is over. The share button hands the text on.
final class TaskLogController: UIViewController, UITableViewDelegate {
    private var errorLines: Set<Int> = []
    private var displayedErrors: Set<Int> = []
    private var followsLatest = true
    private var generation = 0
    private lazy var latestButton = UIButton(type: .system).then {
        $0.setTitle(String(localized: "Jump to Latest"), for: .normal)
        $0.addAction(UIAction { [weak self] _ in
            self?.followsLatest = true
            self?.scrollToLatest()
        }, for: .touchUpInside)
    }

    /// Replacing the target or retrying starts a fresh following session.
    func reset(_ lines: [String], errorLines: Set<Int> = []) {
        generation += 1
        followsLatest = true
        if isViewLoaded { latestButton.isHidden = true }
        update(lines, errorLines: errorLines)
    }

    private func scrollToLatest() {
        guard let last = dataSource.snapshot().itemIdentifiers.last,
              let indexPath = dataSource.indexPath(for: last) else { return }
        tableView.scrollToRow(at: indexPath, at: .bottom, animated: false)
        latestButton.isHidden = true
    }

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        followsLatest = false
        latestButton.isHidden = false
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if !decelerate { resumeFollowingIfAtBottom() }
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        resumeFollowingIfAtBottom()
    }

    private func resumeFollowingIfAtBottom() {
        followsLatest = tableView.contentOffset.y + tableView.bounds.height - tableView.adjustedContentInset.bottom >= tableView.contentSize.height - 24
        latestButton.isHidden = followsLatest
    }
    private let tableView = FirstFillTableView(frame: .zero, style: .plain)
    @objc private dynamic var lines: [String]
    /// A refresh asked for while one is waiting is folded into it: lines
    /// arrive in bursts while a download counts.
    @objc private dynamic var refreshPending = false
    @objc private dynamic var displayedLines: [String] = []
    private let pacing = ListPacing()

    private lazy var dataSource = UITableViewDiffableDataSource<Int, Int>(
        tableView: tableView,
    ) { [weak self] table, indexPath, line in
        let cell = table.dequeueReusableCell(withIdentifier: TaskLogCell.reuseIdentifier, for: indexPath)
        (cell as? TaskLogCell)?.configure(
            number: line + 1,
            message: self.flatMap { $0.displayedLines.indices.contains(line) ? $0.displayedLines[line] : nil } ?? "",
            isError: self?.displayedErrors.contains(line) == true,
        )
        return cell
    }

    init(lines: [String]) {
        self.lines = lines
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("Use init(lines:)")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = String(localized: "Full Log")
        view.backgroundColor = .pageBackground
        navigationItem.largeTitleDisplayMode = .never
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            systemItem: .action,
            primaryAction: UIAction { [weak self] _ in self?.share() },
        ).then { $0.accessibilityLabel = String(localized: "Share Log") }

        tableView.delegate = self
        tableView.showsVerticalScrollIndicator = true
        tableView.contentInsetAdjustmentBehavior = .never
        tableView.backgroundColor = .pageBackground
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 28
        tableView.separatorStyle = .none
        tableView.contentInset = UIEdgeInsets(top: 12, left: 0, bottom: 20, right: 0)
        tableView.allowsSelection = false
        tableView.register(TaskLogCell.self, forCellReuseIdentifier: TaskLogCell.reuseIdentifier)
        view.addSubview(tableView)
        tableView.snp.makeConstraints { x in
            x.edges.equalTo(view.safeAreaLayoutGuide)
        }
        view.addSubview(latestButton)
        latestButton.backgroundColor = .secondarySystemBackground
        latestButton.layer.cornerRadius = 8
        latestButton.isHidden = true
        latestButton.snp.makeConstraints { x in
            x.trailing.bottom.equalTo(view.safeAreaLayoutGuide).inset(12)
            x.height.greaterThanOrEqualTo(44)
        }
        apply()
    }

    /// The task's lines so far; the table catches up at most ten times a
    /// second, following only when the reader has not scrolled away.
    func update(_ lines: [String], errorLines: Set<Int> = []) {
        self.lines = lines
        self.errorLines = errorLines
        guard isViewLoaded, !refreshPending else { return }
        refreshPending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.refreshPending = false
            self?.apply()
        }
    }

    @objc private dynamic func share() {
        let share = UIActivityViewController(activityItems: [lines.joined(separator: "\n")], applicationActivities: nil)
        share.popoverPresentationController?.barButtonItem = navigationItem.rightBarButtonItem
        present(share, animated: true)
    }

    /// Follows the end only while the end is in sight and nobody is
    /// scrolling: reading back up is not interrupted.
    @objc private dynamic func apply() {
        let previous = dataSource.snapshot()
        let follow = followsLatest
        let currentGeneration = generation
        var snapshot = NSDiffableDataSourceSnapshot<Int, Int>()
        snapshot.appendSections([0])
        // a row is its position: the same line can be said twice
        snapshot.appendItems(Array(lines.indices))
        let changed = lines.indices.filter {
            displayedLines.indices.contains($0) && previous.indexOfItem($0) != nil &&
                (displayedLines[$0] != lines[$0] || displayedErrors.contains($0) != errorLines.contains($0))
        }
        guard !tableView.isFilled || displayedLines != lines || displayedErrors != errorLines else { return }
        snapshot.reconfigureItems(changed)
        displayedLines = lines
        displayedErrors = errorLines
        let animated = false
        let last = snapshot.itemIdentifiers.last
        let scroll = { [weak self] in
            guard let self, follow, followsLatest, generation == currentGeneration,
                  !tableView.isTracking, !tableView.isDecelerating,
                  let last, let indexPath = dataSource.indexPath(for: last) else { return }
            tableView.scrollToRow(at: indexPath, at: .bottom, animated: animated)
        }
        if tableView.isFilled {
            dataSource.applyChange(snapshot, to: tableView, animated: animated, completion: scroll)
        } else {
            pacing.begin()
            dataSource.applyFirst(snapshot, to: tableView, completion: scroll)
        }
    }
}

/// A log line: its number in a narrow column, the text beside it.
private final class TaskLogCell: UITableViewCell {
    static let reuseIdentifier = "log"

    private let numberLabel = UILabel()
    private let messageLabel = UILabel()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        backgroundColor = .pageBackground
        selectionStyle = .none
        numberLabel.font = .monospacedSystemFont(
            ofSize: UIFont.preferredFont(forTextStyle: .caption2).pointSize,
            weight: .regular,
        )
        numberLabel.textColor = .secondaryLabel
        numberLabel.textAlignment = .right
        messageLabel.font = .monospacedSystemFont(
            ofSize: UIFont.preferredFont(forTextStyle: .footnote).pointSize,
            weight: .regular,
        )
        messageLabel.textColor = .label
        messageLabel.numberOfLines = 0
        contentView.addSubview(numberLabel)
        contentView.addSubview(messageLabel)
        numberLabel.snp.makeConstraints { x in
            x.leading.equalToSuperview().inset(12)
            x.width.equalTo(32)
            x.firstBaseline.equalTo(messageLabel)
        }
        messageLabel.snp.makeConstraints { x in
            x.leading.equalTo(numberLabel.snp.trailing).offset(12)
            x.trailing.equalToSuperview().inset(20)
            x.top.bottom.equalToSuperview().inset(5)
        }
        // the line is the row; its number is only drawn
        isAccessibilityElement = true
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("Use init(style:reuseIdentifier:)")
    }

    @objc dynamic func configure(number: Int, message: String, isError: Bool) {
        numberLabel.text = String(number)
        messageLabel.text = message
        messageLabel.textColor = isError ? .systemRed : .label
        accessibilityLabel = message
    }

    /// The number stands against the line it numbers: on its right left
    /// to right, on its left right to left.
    override func layoutSubviews() {
        super.layoutSubviews()
        numberLabel.textAlignment = laysOutRightToLeft ? .left : .right
    }
}
