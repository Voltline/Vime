import UIKit

/// Reused cells keep the complete emoji catalog cheap to open and scroll.
final class KeyboardSymbolPanel: UIView, UICollectionViewDataSource, UICollectionViewDelegateFlowLayout {
    var onSelect: ((String) -> Void)?
    var onClose: (() -> Void)?
    private let modes = UISegmentedControl(items: ["Emoji", "颜文字"])
    private let close = UIButton(type: .system)
    private let categories = UIScrollView()
    private let collection: UICollectionView
    private var categoryButtons: [UIButton] = []
    private var selectedGroup = 0
    private var groups: [KeyboardSymbolCatalog.Group] {
        modes.selectedSegmentIndex == 1 ? KeyboardSymbolCatalog.kaomoji : KeyboardSymbolCatalog.emoji.groups
    }
    private var items: [KeyboardSymbolCatalog.Item] { groups.indices.contains(selectedGroup) ? groups[selectedGroup].items : [] }

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
            guard let self else { return }; self.selectedGroup = 0; self.rebuildCategories()
        }, for: .valueChanged)
        close.setTitle("返回键盘", for: .normal)
        close.titleLabel?.font = .systemFont(ofSize: 14, weight: .medium)
        close.accessibilityIdentifier = "vime.symbols.close"
        close.addAction(UIAction { [weak self] _ in self?.onClose?() }, for: .touchUpInside)
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
        for view in [modes, close, categories, collection] { addSubview(view) }
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
            button.addAction(UIAction { [weak self] _ in
                guard let self else { return }; self.selectedGroup = index; self.reloadItems()
            }, for: .touchUpInside)
            categories.addSubview(button)
            return button
        }
        categories.setContentOffset(.zero, animated: false)
        reloadItems(); setNeedsLayout()
    }

    private func reloadItems() {
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
        cell.label.text = item.text
        cell.label.textColor = KeyboardPalette.text
        cell.label.font = .systemFont(ofSize: modes.selectedSegmentIndex == 1 ? 16 : 29)
        cell.contentView.backgroundColor = KeyboardPalette.key
        cell.accessibilityLabel = item.name
        cell.accessibilityIdentifier = "vime.symbol.\(item.text)"
        return cell
    }
    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
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
        override init(frame: CGRect) {
            super.init(frame: frame)
            label.textAlignment = .center; label.adjustsFontSizeToFitWidth = true; label.minimumScaleFactor = 0.5
            contentView.addSubview(label); contentView.layer.cornerRadius = 6
            isAccessibilityElement = true; accessibilityTraits = .button
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override func layoutSubviews() { super.layoutSubviews(); label.frame = contentView.bounds.insetBy(dx: 3, dy: 2) }
    }
}
