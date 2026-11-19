import UIKit

@MainActor
final class DistributionInstallBar: UIView {
    @objc dynamic private(set) lazy var button = UIButton(configuration: .filled())
    @objc private dynamic lazy var detail = UILabel()
    @objc private dynamic lazy var progress = UIProgressView(progressViewStyle: .default)
    @objc private dynamic lazy var percentage = UILabel()
    @objc private dynamic lazy var meter = UIView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .secondarySystemGroupedBackground
        var configuration = UIButton.Configuration.filled()
        configuration.title = String(localized: "Install")
        configuration.baseBackgroundColor = .systemGreen
        configuration.baseForegroundColor = .white
        configuration.cornerStyle = .capsule
        configuration.contentInsets = .init(top: 10, leading: 24, bottom: 10, trailing: 24)
        button.configuration = configuration
        detail.font = .preferredFont(forTextStyle: .footnote)
        detail.adjustsFontForContentSizeCategory = true
        detail.textColor = .secondaryLabel
        detail.numberOfLines = 0
        detail.textAlignment = .center
        progress.progressTintColor = .systemGreen
        progress.isAccessibilityElement = false
        percentage.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        percentage.textColor = .secondaryLabel
        percentage.isAccessibilityElement = false
        meter.addSubview(progress)
        meter.addSubview(percentage)
        let meterHeight = meter.heightAnchor.constraint(equalToConstant: 24)
        meterHeight.priority = .defaultHigh
        meterHeight.isActive = true
        let stack = UIStackView(arrangedSubviews: [button, detail, meter])
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: layoutMarginsGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: layoutMarginsGuide.trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
            button.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor),
            detail.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor),
            meter.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
        show(status: nil)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("Use init(frame:)") }

    @objc dynamic func setButtonTitle(_ title: String) {
        guard var configuration = button.configuration, configuration.title != title else { return }
        configuration.title = title
        button.configuration = configuration
    }

    @objc dynamic func show(status: String?) {
        detail.text = status
        detail.accessibilityValue = nil
        detail.isHidden = status == nil
        meter.isHidden = true
    }

    @objc dynamic func show(progress fraction: Double) {
        let clamped = min(1, max(0, fraction))
        let text = clamped.formatted(.percent.precision(.fractionLength(0)))
        progress.progress = Float(clamped)
        percentage.text = text
        detail.accessibilityValue = text
        meter.isHidden = false
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let width = meter.bounds.width
        progress.frame = CGRect(x: 0, y: meter.bounds.height - 4, width: width, height: 4)
        let size = percentage.intrinsicContentSize
        let edge = width * CGFloat(effectiveUserInterfaceLayoutDirection == .rightToLeft ? 1 - progress.progress : progress.progress)
        percentage.frame = CGRect(x: max(0, min(edge - size.width / 2, width - size.width)), y: 0, width: size.width, height: size.height)
    }
}
