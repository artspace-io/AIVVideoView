import UIKit

/// 主题分区的 header：左侧大标题 + 右侧箭头，点箭头跳转到对应分类的视频网格
final class SectionHeaderView: UICollectionReusableView {
    private let titleLabel = UILabel()
    private let arrowButton = UIButton(type: .system)

    var onTapArrow: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)

        titleLabel.textColor = .white
        titleLabel.font = .boldSystemFont(ofSize: 22)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(titleLabel)

        let chevronImage = UIImage(systemName: "chevron.right")
        arrowButton.setImage(chevronImage, for: .normal)
        arrowButton.tintColor = .white.withAlphaComponent(0.7)
        arrowButton.addTarget(self, action: #selector(handleTap), for: .touchUpInside)
        arrowButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(arrowButton)

        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: arrowButton.leadingAnchor, constant: -8),

            arrowButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            arrowButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            arrowButton.widthAnchor.constraint(equalToConstant: 32),
            arrowButton.heightAnchor.constraint(equalToConstant: 32)
        ])
    }

    required init?(coder: NSCoder) { nil }

    override func prepareForReuse() {
        super.prepareForReuse()
        onTapArrow = nil
    }

    func configure(title: String) {
        titleLabel.text = title
    }

    @objc private func handleTap() {
        onTapArrow?()
    }
}
