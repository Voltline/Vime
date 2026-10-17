import UIKit

final class ClipboardHistoryPanel: UIView, UITableViewDataSource, UITableViewDelegate {
    private let table = UITableView(frame: .zero, style: .plain)
    private let title = UILabel()
    private let back = UIButton(type: .system)
    private let notice = UILabel()
    private let emptyIcon = UIImageView(image: UIImage(systemName: "clipboard"))
    private let empty = UILabel()
    private let clearButton = UIButton(type: .system)
    private var entries: [ClipboardHistoryStore.Entry] = []
    var headerHeight: CGFloat = 56 { didSet { setNeedsLayout() } }
    var contentMargins = UIEdgeInsets(top: 0, left: 12, bottom: 0, right: 12) { didSet { setNeedsLayout() } }
    var onSelect: ((ClipboardHistoryStore.Entry) -> Void)?
    var onClear: (() -> Void)?
    var onBack: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        accessibilityIdentifier = "vime.clipboard.history"
        title.text = "剪贴板历史"; title.font = .systemFont(ofSize: 16, weight: .semibold)
        title.accessibilityTraits = .header
        addSubview(title)
        back.setImage(UIImage(systemName: "chevron.left", withConfiguration: UIImage.SymbolConfiguration(pointSize: 16, weight: .medium)), for: .normal)
        back.accessibilityLabel = "返回快捷设置"
        back.accessibilityIdentifier = "vime.clipboard.history.back"
        back.addAction(UIAction { [weak self] _ in self?.onBack?() }, for: .touchUpInside)
        addSubview(back)
        notice.text = "最近 24 小时 · 仅本机保存"
        notice.font = .systemFont(ofSize: 12)
        addSubview(notice)
        clearButton.setTitle("清空", for: .normal)
        clearButton.titleLabel?.font = .systemFont(ofSize: 15)
        clearButton.accessibilityIdentifier = "vime.clipboard.history.clear"
        clearButton.addAction(UIAction { [weak self] _ in self?.onClear?() }, for: .touchUpInside)
        addSubview(clearButton)
        table.dataSource = self; table.delegate = self
        table.rowHeight = UITableView.automaticDimension
        table.estimatedRowHeight = 106
        table.backgroundColor = .clear
        table.separatorStyle = .none
        table.contentInsetAdjustmentBehavior = .never
        table.keyboardDismissMode = .none
        table.register(HistoryCell.self, forCellReuseIdentifier: "clipboard")
        table.accessibilityIdentifier = "vime.clipboard.history.list"
        if #available(iOS 26.0, *) {
            for edge in [table.topEdgeEffect, table.bottomEdgeEffect, table.leftEdgeEffect, table.rightEdgeEffect] { edge.isHidden = true }
        }
        addSubview(table)
        emptyIcon.contentMode = .scaleAspectFit; emptyIcon.isAccessibilityElement = false
        addSubview(emptyIcon)
        empty.numberOfLines = 0; empty.textAlignment = .center
        empty.font = .systemFont(ofSize: 13)
        empty.accessibilityIdentifier = "vime.clipboard.history.empty"
        addSubview(empty)
        applyTheme()
        present([], message: "正在读取历史…")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func present(_ entries: [ClipboardHistoryStore.Entry], message: String? = nil) {
        self.entries = entries
        empty.text = message ?? "暂无剪贴板历史\n开启功能后，近期复制的文字会保留在这里"
        empty.isHidden = !entries.isEmpty; emptyIcon.isHidden = !entries.isEmpty
        table.isHidden = entries.isEmpty
        clearButton.isEnabled = !entries.isEmpty
        table.reloadData()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let left = contentMargins.left, right = bounds.width - contentMargins.right
        let diameter = min(36, headerHeight - 8)
        back.frame = CGRect(x: left, y: (headerHeight - diameter) / 2, width: diameter, height: diameter)
        back.layer.cornerRadius = diameter / 2
        clearButton.frame = CGRect(x: right - 50, y: 0, width: 50, height: headerHeight)
        title.frame = CGRect(x: back.frame.maxX + 12, y: 0,
            width: max(0, clearButton.frame.minX - back.frame.maxX - 24), height: headerHeight)
        notice.frame = CGRect(x: left + 4, y: headerHeight, width: max(0, right - left - 8), height: 28)
        table.frame = CGRect(x: left, y: notice.frame.maxY, width: max(0, right - left),
            height: max(0, bounds.height - notice.frame.maxY))
        emptyIcon.frame = CGRect(x: bounds.midX - 16, y: max(notice.frame.maxY, table.frame.midY - 40), width: 32, height: 32)
        empty.frame = CGRect(x: left + 8, y: emptyIcon.frame.maxY + 8, width: max(0, right - left - 16), height: 48)
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { entries.count }
    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "clipboard", for: indexPath) as! HistoryCell
        cell.present(entries[indexPath.row])
        return cell
    }
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard entries.indices.contains(indexPath.row) else { return }
        onSelect?(entries[indexPath.row])
    }

    func applyTheme() {
        title.textColor = KeyboardPalette.text
        back.backgroundColor = KeyboardPalette.key; back.tintColor = KeyboardPalette.text
        clearButton.tintColor = KeyboardPalette.accent
        for item in [notice, empty] { item.textColor = KeyboardPalette.text.withAlphaComponent(0.55) }
        emptyIcon.tintColor = KeyboardPalette.text.withAlphaComponent(0.35)
        table.reloadData()
    }

    private final class HistoryCell: UITableViewCell {
        private let card = UIView()
        private let preview = UILabel()
        private let time = UILabel()
        private let action = UILabel()
        private let arrow = UIImageView(image: UIImage(systemName: "chevron.right"))

        override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
            super.init(style: style, reuseIdentifier: reuseIdentifier)
            backgroundColor = .clear; selectionStyle = .none
            card.layer.cornerRadius = 14; card.layer.cornerCurve = .continuous
            contentView.addSubview(card)
            card.translatesAutoresizingMaskIntoConstraints = false
            preview.font = .systemFont(ofSize: 16); preview.numberOfLines = 2
            preview.lineBreakMode = .byTruncatingTail
            time.font = .systemFont(ofSize: 12)
            action.font = .systemFont(ofSize: 12); action.text = "点击输入"
            arrow.contentMode = .scaleAspectFit
            for view in [preview, time, action, arrow] { view.translatesAutoresizingMaskIntoConstraints = false; card.addSubview(view) }
            NSLayoutConstraint.activate([
                card.leadingAnchor.constraint(equalTo: contentView.leadingAnchor), card.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
                card.topAnchor.constraint(equalTo: contentView.topAnchor), card.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -10),
                preview.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 16), preview.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -16),
                preview.topAnchor.constraint(equalTo: card.topAnchor, constant: 13),
                time.leadingAnchor.constraint(equalTo: preview.leadingAnchor), time.topAnchor.constraint(equalTo: preview.bottomAnchor, constant: 10),
                time.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -12),
                action.centerYAnchor.constraint(equalTo: time.centerYAnchor), action.trailingAnchor.constraint(equalTo: arrow.leadingAnchor, constant: -6),
                time.trailingAnchor.constraint(lessThanOrEqualTo: action.leadingAnchor, constant: -8),
                arrow.trailingAnchor.constraint(equalTo: preview.trailingAnchor), arrow.centerYAnchor.constraint(equalTo: time.centerYAnchor),
                arrow.widthAnchor.constraint(equalToConstant: 8), arrow.heightAnchor.constraint(equalToConstant: 13)
            ])
            isAccessibilityElement = true; accessibilityTraits = .button
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        func present(_ entry: ClipboardHistoryStore.Entry) {
            preview.text = String(String.UnicodeScalarView(entry.text.unicodeScalars.prefix(240)))
            let age = Date().timeIntervalSince(entry.capturedAt)
            time.text = age < 60 ? "刚刚" : age < 3600 ? "\(Int(age / 60)) 分钟前" : entry.capturedAt.formatted(date: .omitted, time: .shortened)
            card.backgroundColor = KeyboardPalette.key
            preview.textColor = KeyboardPalette.text
            for item in [time, action] { item.textColor = KeyboardPalette.text.withAlphaComponent(0.55) }
            arrow.tintColor = KeyboardPalette.text.withAlphaComponent(0.55)
            accessibilityIdentifier = "vime.clipboard.history.item.\(entry.id)"
            accessibilityLabel = preview.text
            accessibilityValue = time.text
            accessibilityHint = "输入这条历史记录的完整文本"
        }
    }
}
