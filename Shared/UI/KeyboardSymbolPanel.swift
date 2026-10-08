import UIKit
import CoreText

/// Reused cells keep the complete emoji catalog cheap to open and scroll.
final class KeyboardSymbolPanel: UIView, UICollectionViewDataSource, UICollectionViewDelegateFlowLayout {
    enum Mode: Int { case emoji, kaomoji, symbols }
    var onSelect: ((String) -> Void)?
    var onClose: (() -> Void)?
    var onFeedback: (() -> Void)?
    private let modes = UISegmentedControl(items: ["Emoji", "颜文字", "符号"])
    private let loading = UIActivityIndicatorView(style: .medium)
    private let close = UIButton(type: .system)
    private let categories = UIScrollView()
    private let collection: UICollectionView
    private var categoryButtons: [UIButton] = []
    private var selectedGroup = 0
    private var emojiRevision = 0
    private var visibleEmoji: [KeyboardSymbolCatalog.Item] = []
    private var loadedEmojiGroup: String?
    private var groups: [KeyboardSymbolCatalog.Group] {
        switch Mode(rawValue: modes.selectedSegmentIndex) ?? .emoji {
        case .emoji: KeyboardSymbolCatalog.emoji.groups
        case .kaomoji: KeyboardSymbolCatalog.kaomoji
        case .symbols: KeyboardSymbolCatalog.symbols
        }
    }
    private var items: [KeyboardSymbolCatalog.Item] {
        if modes.selectedSegmentIndex == Mode.emoji.rawValue { return visibleEmoji }
        return groups.indices.contains(selectedGroup) ? groups[selectedGroup].items : []
    }

    func selectMode(_ mode: Mode) {
        guard modes.selectedSegmentIndex != mode.rawValue else { return }
        modes.selectedSegmentIndex = mode.rawValue; selectedGroup = 0; rebuildCategories()
    }

    override init(frame: CGRect) {
        let layout = UICollectionViewFlowLayout()
        layout.minimumInteritemSpacing = 4; layout.minimumLineSpacing = 4
        layout.sectionInset = UIEdgeInsets(top: 4, left: 6, bottom: 6, right: 6)
        collection = UICollectionView(frame: .zero, collectionViewLayout: layout)
        super.init(frame: frame)
        accessibilityIdentifier = "vime.symbols"
        backgroundColor = KeyboardTouchBacking.color
        collection.backgroundColor = KeyboardTouchBacking.color
        collection.accessibilityIdentifier = "vime.symbols.grid"
        collection.dataSource = self; collection.delegate = self
        collection.register(SymbolCell.self, forCellWithReuseIdentifier: "symbol")
        collection.alwaysBounceVertical = true
        modes.selectedSegmentIndex = 0
        modes.accessibilityIdentifier = "vime.symbols.mode"
        modes.addAction(UIAction { [weak self] _ in
            guard let self else { return }; self.onFeedback?(); self.selectedGroup = 0; self.rebuildCategories()
        }, for: .valueChanged)
        close.setTitle("返回键盘", for: .normal)
        close.titleLabel?.font = .systemFont(ofSize: 14, weight: .medium)
        close.accessibilityIdentifier = "vime.symbols.close"
        close.addAction(UIAction { [weak self] _ in self?.onFeedback?(); self?.onClose?() }, for: .touchUpInside)
        categories.showsHorizontalScrollIndicator = false
        // Apply the same policy as the candidate strip: automatic Liquid Glass
        // scroll edges obscure short keyboard grids and category controls.
        for scroll in [categories, collection] {
            scroll.contentInsetAdjustmentBehavior = .never
            if #available(iOS 26.0, *) {
                for edge in [scroll.topEdgeEffect, scroll.bottomEdgeEffect, scroll.leftEdgeEffect, scroll.rightEdgeEffect] {
                    edge.isHidden = true
                }
            }
        }
        loading.hidesWhenStopped = true
        for view in [modes, close, categories, collection, loading] { addSubview(view) }
        rebuildCategories()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        let top = KeyboardMetrics.toolbarTopInset
        close.frame = CGRect(x: 6, y: top, width: 82, height: 34)
        modes.frame = CGRect(x: 96, y: top + 2, width: bounds.width - 104, height: 30)
        categories.frame = CGRect(x: 0, y: top + 36, width: bounds.width, height: 28)
        var x: CGFloat = 8
        for button in categoryButtons {
            button.frame = CGRect(x: x, y: 0, width: 58, height: 28); x += 62
        }
        categories.contentSize = CGSize(width: x, height: 28)
        collection.frame = CGRect(x: 0, y: top + 64, width: bounds.width, height: max(0, bounds.height - top - 64))
        loading.center = CGPoint(x: bounds.midX, y: collection.frame.midY)
        collection.collectionViewLayout.invalidateLayout()
    }

    private func rebuildCategories() {
        categoryButtons.forEach { $0.removeFromSuperview() }
        categoryButtons = groups.enumerated().map { index, group in
            let button = UIButton(type: .system)
            button.setTitle(KeyboardSymbolCatalog.title(for: group.name), for: .normal)
            button.titleLabel?.font = .systemFont(ofSize: 13)
            button.layer.cornerRadius = 6
            button.accessibilityIdentifier = "vime.symbols.category.\(index)"
            button.addAction(UIAction { [weak self, weak button] _ in
                guard let self else { return }; self.onFeedback?(); self.selectedGroup = index; self.reloadItems()
                if let button { self.categories.scrollRectToVisible(button.frame.insetBy(dx: -8, dy: 0), animated: true) }
            }, for: .touchUpInside)
            categories.addSubview(button)
            return button
        }
        categories.setContentOffset(.zero, animated: false)
        reloadItems(); setNeedsLayout()
    }

    private func reloadItems() {
        emojiRevision += 1
        if modes.selectedSegmentIndex == Mode.emoji.rawValue, groups.indices.contains(selectedGroup) {
            let group = groups[selectedGroup]
            if loadedEmojiGroup != group.name {
                visibleEmoji = []; loadedEmojiGroup = nil; loading.startAnimating()
                let revision = emojiRevision
                KeyboardEmojiAvailability.load(group) { [weak self] items in
                    guard let self, self.emojiRevision == revision else { return }
                    self.visibleEmoji = items; self.loadedEmojiGroup = group.name
                    self.loading.stopAnimating(); self.collection.reloadData()
                }
            } else { loading.stopAnimating() }
        } else { loading.stopAnimating() }
        for (i, button) in categoryButtons.enumerated() {
            button.backgroundColor = i == selectedGroup ? KeyboardPalette.utility : KeyboardTouchBacking.color
            button.setTitleColor(i == selectedGroup ? KeyboardPalette.accent : KeyboardPalette.text, for: .normal)
            button.accessibilityTraits = i == selectedGroup ? [.button, .selected] : [.button]
        }
        collection.reloadData(); collection.setContentOffset(.zero, animated: false)
    }

    func applyTheme() {
        close.tintColor = KeyboardPalette.accent
        modes.selectedSegmentTintColor = KeyboardPalette.utility
        reloadItems()
    }

    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int { items.count }
    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: "symbol", for: indexPath) as! SymbolCell
        let item = items[indexPath.item]
        let isEmoji = modes.selectedSegmentIndex == Mode.emoji.rawValue
        cell.label.text = isEmoji ? nil : item.text
        cell.glyph.image = isEmoji ? EmojiGlyph.image(item.text) : nil
        cell.glyph.isHidden = !isEmoji; cell.label.isHidden = isEmoji
        cell.label.textColor = KeyboardPalette.text
        cell.label.font = .systemFont(ofSize: modes.selectedSegmentIndex == Mode.kaomoji.rawValue ? 16 :
            modes.selectedSegmentIndex == Mode.symbols.rawValue ? 23 : 29)
        cell.contentView.backgroundColor = KeyboardPalette.key
        cell.accessibilityLabel = item.name
        cell.accessibilityIdentifier = "vime.symbol.\(item.text)"
        return cell
    }
    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        guard items.indices.contains(indexPath.item) else { return }
        onSelect?(items[indexPath.item].text)
        collectionView.deselectItem(at: indexPath, animated: false)
    }
    func collectionView(_ collectionView: UICollectionView, layout collectionViewLayout: UICollectionViewLayout,
                        sizeForItemAt indexPath: IndexPath) -> CGSize {
        let columns = modes.selectedSegmentIndex == 1 ? max(2, Int(bounds.width / 145)) : max(5, Int((bounds.width - 8) / 48))
        return CGSize(width: floor((bounds.width - 12 - CGFloat(columns - 1) * 4) / CGFloat(columns)), height: 44)
    }

    private final class SymbolCell: UICollectionViewCell {
        let label = UILabel()
        let glyph = UIImageView()
        override init(frame: CGRect) {
            super.init(frame: frame)
            label.textAlignment = .center; label.adjustsFontSizeToFitWidth = true; label.minimumScaleFactor = 0.5
            contentView.addSubview(label); contentView.layer.cornerRadius = 6
            glyph.contentMode = .scaleAspectFit; contentView.addSubview(glyph)
            isAccessibilityElement = true; accessibilityTraits = .button
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override func layoutSubviews() {
            super.layoutSubviews(); label.frame = contentView.bounds.insetBy(dx: 3, dy: 2)
            glyph.frame = contentView.bounds.insetBy(dx: 4, dy: 4)
        }
    }

    /// Use the same native font as availability detection and fit its ink bounds
    /// into a cell, including composite glyphs with more than one skin tone.
    private enum EmojiGlyph {
        static let cache: NSCache<NSString, UIImage> = {
            let cache = NSCache<NSString, UIImage>(); cache.countLimit = 180; return cache
        }()
        static let font = CTFontCreateWithName("AppleColorEmoji" as CFString, 30, nil)
        static func image(_ text: String) -> UIImage {
            if let image = cache.object(forKey: text as NSString) { return image }
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: text,
                attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font]))
            let image = UIGraphicsImageRenderer(size: CGSize(width: 36, height: 36)).image { renderer in
                let context = renderer.cgContext
                let ink = CTLineGetImageBounds(line, context)
                guard !ink.isEmpty else { return }
                let scale = min(1, min(34 / ink.width, 34 / ink.height))
                context.translateBy(x: 18, y: 18); context.scaleBy(x: scale, y: -scale)
                context.textPosition = CGPoint(x: -ink.midX, y: -ink.midY)
                CTLineDraw(line, context)
            }
            cache.setObject(image, forKey: text as NSString)
            return image
        }
    }
}
