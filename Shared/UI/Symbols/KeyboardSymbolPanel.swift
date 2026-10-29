import UIKit

/// One continuous horizontal collection across all symbol categories.
final class KeyboardSymbolPanel: UIView, UICollectionViewDataSource, UICollectionViewDelegate, UICollectionViewDataSourcePrefetching {
    enum Mode: Int, CaseIterable { case emoji, kaomoji, symbols }
    var onSelect: ((String) -> Void)?
    var onClose: (() -> Void)?
    var onFeedback: (() -> Void)?
    /// An emoji was inserted; the keyboard records it for the recent category.
    var onEmojiUse: ((String) -> Void)?
    var onSearch: (() -> Void)?
    /// Recently used emoji, shown as the first emoji category when not empty.
    var recents: [String] = [] {
        didSet {
            guard recents != oldValue else { return }
            let current = locations[selectedSection]
            recentItems = recents.map { KeyboardSymbolCatalog.Item(text: $0, name: KeyboardSymbolCatalog.emojiNames[$0] ?? $0) }
            cancelPrefetches()
            locations = Self.locations(hasRecents: !recents.isEmpty)
            selectedSection = locations.firstIndex { $0.mode == current.mode && $0.group == current.group } ?? 0
            headerSelection = nil
            rebuildCategories(for: displayedMode)
            layout.itemWidths = itemWidths()
            collection.reloadData(); layout.invalidateLayout()
            if collection.bounds.width > 0 { showSection(selectedSection, feedback: false) }
        }
    }
    var compact = false { didSet { if oldValue != compact { setNeedsLayout() } } }
    private let modes = UISegmentedControl(items: ["Emoji", String(localized: "颜文字"), String(localized: "符号")])
    private let close = UIButton(type: .system)
    private let search = UIButton(type: .system)
    private let categories = UIScrollView()
    private let categoryIndicator = UIView()
    private let viewport = UIView()
    private let loading = UIActivityIndicatorView(style: .medium)
    private let layout = SymbolLayout()
    private let collection: UICollectionView
    private var categoryButtons: [UIButton] = []
    private var displayedMode: Mode = .emoji
    private var selectedSection = 0
    private var layingOut = false
    private var prefetches: [IndexPath: UUID] = [:]
    private var lookahead: [IndexPath: UUID] = [:]
    private var previousOffset: CGFloat = 0
    private var previousScrollTime: CFTimeInterval = 0
    private var scrollSpeed: CGFloat = 0
    private var scrollDirection: CGFloat = 1
    private let cells = NSHashTable<SymbolCell>.weakObjects()
    private var headerProgress: CGFloat?
    private var headerSelection: Int?
    private var emojiItems: [Int: [KeyboardSymbolCatalog.Item]] = [:]
    private var recentItems: [KeyboardSymbolCatalog.Item] = []
    /// Group -1 is the recent emoji category.
    private struct Location { let mode: Mode; let group: Int }
    private static func groups(for mode: Mode) -> [KeyboardSymbolCatalog.Group] {
        switch mode {
        case .emoji: KeyboardSymbolCatalog.emoji.groups
        case .kaomoji: KeyboardSymbolCatalog.kaomoji
        case .symbols: KeyboardSymbolCatalog.symbols
        }
    }
    private var locations = locations(hasRecents: false)
    private static func locations(hasRecents: Bool) -> [Location] {
        (hasRecents ? [Location(mode: .emoji, group: -1)] : []) + Mode.allCases.flatMap { mode in
            groups(for: mode).indices.map { Location(mode: mode, group: $0) }
        }
    }
    private func items(in section: Int) -> [KeyboardSymbolCatalog.Item] {
        let location = locations[section]
        if location.group < 0 { return recentItems }
        return location.mode == .emoji ? emojiItems[location.group] ?? [] : Self.groups(for: location.mode)[location.group].items
    }
    /// Category tabs follow the sections of one mode, recent emoji first.
    private func tabIndex(of location: Location) -> Int {
        location.group + (location.mode == .emoji && !recentItems.isEmpty ? 1 : 0)
    }

    override init(frame: CGRect) {
        collection = UICollectionView(frame: .zero, collectionViewLayout: layout)
        super.init(frame: frame)
        accessibilityIdentifier = "vime.symbols"
        backgroundColor = KeyboardTouchBacking.color
        viewport.accessibilityIdentifier = "vime.symbols.pages"
        viewport.clipsToBounds = true
        collection.accessibilityIdentifier = "vime.symbols.grid"
        collection.backgroundColor = .clear
        collection.alwaysBounceHorizontal = true
        collection.showsHorizontalScrollIndicator = false
        collection.showsVerticalScrollIndicator = false
        collection.dataSource = self; collection.delegate = self; collection.prefetchDataSource = self
        collection.register(SymbolCell.self, forCellWithReuseIdentifier: "symbol")
        Self.configureScroll(collection); Self.configureScroll(categories)
        modes.accessibilityIdentifier = "vime.symbols.mode"
        modes.selectedSegmentIndex = 0
        modes.addAction(UIAction { [weak self] _ in
            guard let self, let mode = Mode(rawValue: self.modes.selectedSegmentIndex) else { return }
            self.showSection(self.firstSection(of: mode))
        }, for: .valueChanged)
        close.setTitle(String(localized: "返回键盘"), for: .normal)
        close.titleLabel?.font = .systemFont(ofSize: 14, weight: .medium)
        close.titleLabel?.adjustsFontSizeToFitWidth = true; close.titleLabel?.minimumScaleFactor = 0.7
        close.accessibilityIdentifier = "vime.symbols.close"
        search.setImage(UIImage(systemName: "magnifyingglass", withConfiguration: UIImage.SymbolConfiguration(pointSize: 15, weight: .medium)), for: .normal)
        search.accessibilityLabel = String(localized: "搜索表情")
        search.accessibilityIdentifier = "vime.symbols.search"
        search.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            self.collection.setContentOffset(self.collection.contentOffset, animated: false)
            self.onFeedback?(); self.onSearch?()
        }, for: .touchUpInside)
        close.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            self.collection.setContentOffset(self.collection.contentOffset, animated: false)
            self.onFeedback?(); self.onClose?()
        }, for: .touchUpInside)
        categories.showsHorizontalScrollIndicator = false
        categories.delegate = self
        categories.accessibilityIdentifier = "vime.symbols.categories"
        categoryIndicator.accessibilityIdentifier = "vime.symbols.category.indicator"
        categoryIndicator.isUserInteractionEnabled = false
        categoryIndicator.layer.cornerRadius = 8
        categories.addSubview(categoryIndicator)
        for view in [modes, close, search, categories, viewport] { addSubview(view) }
        viewport.addSubview(collection); viewport.addSubview(loading)
        loading.hidesWhenStopped = true; loading.startAnimating()
        rebuildCategories(for: .emoji)
        registerForTraitChanges(UITraitCollection.systemTraitsAffectingColorAppearance) {
            (panel: KeyboardSymbolPanel, _: UITraitCollection) in
            panel.traitCollection.performAsCurrent { panel.applyTheme() }
        }
        registerForTraitChanges([UITraitDisplayScale.self]) {
            (panel: KeyboardSymbolPanel, _: UITraitCollection) in panel.applyTheme()
        }
        for (index, group) in Self.groups(for: .emoji).enumerated() {
            KeyboardEmojiAvailability.load(group) { [weak self] items in
                guard let self else { return }
                self.emojiItems[index] = items
                if self.emojiItems.count == Self.groups(for: .emoji).count {
                    self.loading.stopAnimating()
                    let section = self.selectedSection
                    self.collection.reloadData(); self.layout.invalidateLayout()
                    self.layoutIfNeeded(); self.showSection(section, feedback: false)
                }
            }
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    private static func configureScroll(_ scroll: UIScrollView) {
        scroll.contentInsetAdjustmentBehavior = .never
        if #available(iOS 26.0, *) {
            for edge in [scroll.topEdgeEffect, scroll.bottomEdgeEffect, scroll.leftEdgeEffect, scroll.rightEdgeEffect] { edge.isHidden = true }
        }
    }
    private func section(for mode: Mode, group: Int) -> Int {
        locations.firstIndex { $0.mode == mode && $0.group == group }!
    }
    private func firstSection(of mode: Mode) -> Int {
        locations.firstIndex { $0.mode == mode }!
    }
    func selectMode(_ mode: Mode) {
        if locations[selectedSection].mode != mode { showSection(firstSection(of: mode)) }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let anchor = layout.anchor(at: collection.contentOffset.x)
        let oldSize = collection.bounds.size
        let top = KeyboardMetrics.toolbarTopInset
        let metrics = KeyboardMetrics(width: bounds.width, compact: compact, showsFooter: false)
        // Localized titles vary widely in length; fit the text rather than truncate it.
        let closeWidth = min(max(82, Self.textWidth(String(localized: "返回键盘"), font: close.titleLabel?.font) + 8), bounds.width * 0.4)
        close.frame = CGRect(x: 6, y: top, width: closeWidth, height: 34)
        search.frame = CGRect(x: bounds.width - 40, y: top, width: 34, height: 34)
        modes.frame = CGRect(x: close.frame.maxX + 8, y: top + 2, width: max(0, search.frame.minX - close.frame.maxX - 14), height: 30)
        categories.frame = CGRect(x: 0, y: top + 32, width: bounds.width, height: 28)
        close.setTitle(compact ? nil : String(localized: "返回键盘"), for: .normal)
        close.accessibilityLabel = String(localized: "返回键盘")
        close.setImage(compact ? UIImage(systemName: "chevron.up") : nil, for: .normal)
        close.backgroundColor = compact ? KeyboardPalette.key : .clear
        close.tintColor = compact ? .secondaryLabel : KeyboardPalette.accent
        search.backgroundColor = close.backgroundColor
        search.tintColor = compact ? .secondaryLabel : KeyboardPalette.text
        close.layer.cornerRadius = compact ? metrics.toolbarButtonDiameter / 2 : 0
        search.layer.cornerRadius = close.layer.cornerRadius
        if compact {
            close.frame = metrics.trailingToolbarFrame(index: 0)
            search.frame = metrics.trailingToolbarFrame(index: 1)
            modes.frame = CGRect(x: metrics.contentLeft, y: top,
                width: min(320, search.frame.minX - KeyboardMetrics.toolbarGap - metrics.contentLeft), height: metrics.toolbarButtonDiameter)
            categories.frame = CGRect(x: metrics.contentLeft, y: metrics.headerHeight, width: metrics.contentWidth, height: 28)
        }
        layoutCategories()
        let gridTop = categories.frame.maxY + (compact ? 4 : 0)
        layingOut = true
        viewport.frame = CGRect(x: compact ? metrics.contentLeft : 0, y: gridTop,
            width: compact ? metrics.contentWidth : bounds.width, height: max(0, bounds.height - gridTop))
        collection.frame = viewport.bounds
        loading.center = CGPoint(x: viewport.bounds.midX, y: viewport.bounds.midY)
        if oldSize != collection.bounds.size {
            layout.compact = compact
            layout.itemWidths = itemWidths()
            layout.invalidateLayout(); collection.layoutIfNeeded()
            let offset = anchor.map { layout.offset(for: $0) } ?? layout.start(of: selectedSection)
            collection.setContentOffset(CGPoint(x: offset, y: 0), animated: false)
        }
        layingOut = false
        syncHeaderToScrolling()
        prepareAhead()
    }
    private func itemWidths() -> [CGFloat] {
        locations.map { location in
            let width = collection.bounds.width
            let spacing: CGFloat = location.mode == .emoji ? 42 : 48
            let columns = location.mode == .kaomoji ? max(2, Int(width / 145)) : max(5, Int((width - 8) / spacing))
            return max(1, floor((width - 12 - CGFloat(columns - 1) * 4) / CGFloat(columns)))
        }
    }
    /// Tabs keep a 52pt minimum and grow to fit longer localized titles.
    private func layoutCategories() {
        headerProgress = nil
        var x: CGFloat = compact ? 0 : 8
        for button in categoryButtons {
            let width = max(52, Self.textWidth(button.title(for: .normal) ?? "", font: button.titleLabel?.font) + 16)
            button.frame = CGRect(x: x, y: 0, width: width, height: 28)
            x += width + 4
        }
        categories.contentSize = CGSize(width: x - 4 + (compact ? 0 : 8), height: 28)
    }
    private static func textWidth(_ text: String, font: UIFont?) -> CGFloat {
        ceil((text as NSString).size(withAttributes: [.font: font ?? .systemFont(ofSize: 14)]).width)
    }
    /// The indicator slides between neighbouring tab frames as `progress` crosses a boundary.
    private func indicatorFrame(at progress: CGFloat) -> CGRect {
        guard let last = categoryButtons.indices.last else { return .zero }
        let lower = max(0, min(last, Int(progress.rounded(.down)))), upper = min(last, lower + 1)
        let fraction = progress - CGFloat(lower), from = categoryButtons[lower].frame, to = categoryButtons[upper].frame
        return CGRect(x: from.minX + (to.minX - from.minX) * fraction, y: 0,
            width: from.width + (to.width - from.width) * fraction, height: 28)
    }
    private func rebuildCategories(for mode: Mode) {
        displayedMode = mode
        categoryButtons.forEach { $0.removeFromSuperview() }
        let recent = mode == .emoji && !recentItems.isEmpty ? [(-1, String(localized: "最近"))] : []
        let titles = recent + Self.groups(for: mode).enumerated().map { ($0, KeyboardSymbolCatalog.title(for: $1.name)) }
        categoryButtons = titles.map { index, title in
            let button = UIButton(type: .system)
            button.setTitle(title, for: .normal)
            button.titleLabel?.font = .systemFont(ofSize: 14)
            button.accessibilityIdentifier = index < 0 ? "vime.symbols.category.recent" : "vime.symbols.category.\(index)"
            button.addAction(UIAction { [weak self] _ in
                guard let self else { return }
                self.showSection(self.section(for: mode, group: index))
            }, for: .touchUpInside)
            categories.addSubview(button)
            return button
        }
        layoutCategories()
    }
    private func syncHeaderToScrolling() {
        let timing = KeyboardPerformance.start()
        defer { KeyboardPerformance.record(.symbolHeaderUpdate, since: timing) }
        guard !layingOut, layout.sections.count == locations.count else { return }
        let offset = max(0, collection.contentOffset.x)
        let lower = layout.section(at: offset), upper = min(lower + 1, locations.count - 1)
        let transition = min(layout.sections[lower].width, layout.itemWidths[lower] + 4)
        let fraction: CGFloat = lower == upper ? 0 : max(0, min(1, (offset - layout.start(of: upper) + transition) / transition))
        let previewSection = fraction < 0.5 ? lower : upper
        let preview = locations[previewSection]
        loading.isHidden = preview.mode != .emoji || !loading.isAnimating
        selectedSection = previewSection
        if displayedMode != preview.mode { rebuildCategories(for: preview.mode) }
        if modes.selectedSegmentIndex != preview.mode.rawValue { modes.selectedSegmentIndex = preview.mode.rawValue }
        let progress = locations[lower].mode == locations[upper].mode
            ? CGFloat(tabIndex(of: locations[lower])) + fraction : CGFloat(tabIndex(of: preview))
        if headerSelection != previewSection {
            headerSelection = previewSection
            for (index, button) in categoryButtons.enumerated() {
                let selected = index == tabIndex(of: preview)
                button.backgroundColor = .clear
                button.setTitleColor(selected ? KeyboardPalette.accent : KeyboardPalette.text, for: .normal)
                button.accessibilityTraits = selected ? [.button, .selected] : [.button]
            }
        }
        guard headerProgress != progress else { return }
        headerProgress = progress
        categoryIndicator.backgroundColor = KeyboardPalette.utility
        categoryIndicator.frame = indicatorFrame(at: progress)
        let maximum = max(0, categories.contentSize.width - categories.bounds.width)
        categories.setContentOffset(CGPoint(x: max(0, min(maximum, categoryIndicator.frame.midX - categories.bounds.width / 2)), y: 0), animated: false)
    }
    private func showSection(_ section: Int, feedback: Bool = true) {
        selectedSection = section
        if feedback { onFeedback?() }
        setNeedsLayout(); layoutIfNeeded(); collection.layoutIfNeeded()
        collection.setContentOffset(CGPoint(x: layout.start(of: section), y: 0), animated: false)
        syncHeaderToScrolling()
    }
    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        if scrollView === collection {
            let delta = collection.contentOffset.x - previousOffset
            let now = CACurrentMediaTime()
            let elapsed = now - previousScrollTime
            scrollSpeed = elapsed > 0.002 && elapsed < 0.1 ? abs(delta) / elapsed : 0
            previousScrollTime = now
            if abs(delta) > 0.5 { scrollDirection = delta > 0 ? 1 : -1 }
            previousOffset = collection.contentOffset.x
            syncHeaderToScrolling(); prepareAhead()
        }
    }
    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        if scrollView === categories { collection.setContentOffset(collection.contentOffset, animated: false) }
    }
    /// UIKit's prefetch callbacks are opportunistic. Keep a bounded strip of
    /// actual pixels ready in the direction of travel, across section borders.
    /// Reverse travel cancels obsolete work and promotes the new leading edge.
    private func prepareAhead() {
        guard !layingOut, !isHidden, collection.bounds.width > 0, !layout.sections.isEmpty else { return }
        let bounds = collection.bounds
        let velocity = -collection.panGestureRecognizer.velocity(in: collection).x
        if collection.isDragging, abs(velocity) > 100 { scrollDirection = velocity > 0 ? 1 : -1 }
        let distance = max(bounds.width, min(bounds.width * 2, max(scrollSpeed, abs(velocity)) * 0.12))
        let ahead = CGRect(x: scrollDirection > 0 ? bounds.maxX : bounds.minX - distance,
            y: 0, width: distance, height: bounds.height)
        let reverseDistance = max(320, bounds.width * 0.75)
        let behind = CGRect(x: scrollDirection > 0 ? bounds.minX - reverseDistance : bounds.maxX,
            y: 0, width: reverseDistance, height: bounds.height)
        func paths(in rect: CGRect, forward: Bool, limit: Int) -> [IndexPath] {
            let attributes = layout.layoutAttributesForElements(in: rect) ?? []
            return attributes.filter { locations[$0.indexPath.section].mode == .emoji }
                .sorted { forward ? $0.frame.minX < $1.frame.minX : $0.frame.minX > $1.frame.minX }
                .prefix(limit).map(\.indexPath)
        }
        let targets = paths(in: ahead, forward: scrollDirection > 0, limit: 56)
            + paths(in: behind, forward: scrollDirection < 0, limit: 28)
        let wanted = Set(targets)
        for path in Array(lookahead.keys) {
            if !wanted.contains(path) || !KeyboardEmojiImages.isPending(lookahead[path]!) {
                KeyboardEmojiImages.cancel(lookahead.removeValue(forKey: path))
            }
        }
        let scale = window?.screen.scale ?? traitCollection.displayScale
        KeyboardEmojiImages.protect(targets.compactMap { path in
            let values = items(in: path.section)
            return path.item < values.count ? values[path.item].text : nil
        }, scale: scale)
        for path in targets where lookahead[path] == nil {
            let values = items(in: path.section)
            guard path.item < values.count else { continue }
            lookahead[path] = KeyboardEmojiImages.request(values[path.item].text, scale: scale, priority: .anticipated)
        }
        collection.visibleCells.compactMap { $0 as? SymbolCell }.forEach { $0.loadImage(priority: .visible) }
    }
    private func cancelPrefetches() {
        for token in prefetches.values { KeyboardEmojiImages.cancel(token) }
        for token in lookahead.values { KeyboardEmojiImages.cancel(token) }
        prefetches.removeAll(); lookahead.removeAll()
        KeyboardEmojiImages.protect([], scale: window?.screen.scale ?? traitCollection.displayScale)
    }
    func applyTheme() {
        traitCollection.performAsCurrent { KeyboardEmojiImages.synchronizeAppearance() }
        cancelPrefetches()
        headerSelection = nil; headerProgress = nil
        modes.selectedSegmentTintColor = KeyboardPalette.utility
        collection.reloadData(); syncHeaderToScrolling()
    }
    func numberOfSections(in collectionView: UICollectionView) -> Int { locations.count }
    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int { items(in: section).count }
    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let timing = KeyboardPerformance.start()
        defer { KeyboardPerformance.record(.symbolCellConfiguration, since: timing) }
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: "symbol", for: indexPath) as! SymbolCell
        cells.add(cell)
        let item = items(in: indexPath.section)[indexPath.item], mode = locations[indexPath.section].mode
        cell.configure(item.text, emoji: mode == .emoji, scale: window?.screen.scale ?? traitCollection.displayScale)
        cell.label.textColor = KeyboardPalette.text
        cell.label.font = .systemFont(ofSize: mode == .kaomoji ? 16 : mode == .symbols ? 23 : 29)
        cell.contentView.backgroundColor = mode == .emoji ? .clear : KeyboardPalette.key
        cell.accessibilityLabel = item.name
        cell.accessibilityIdentifier = "vime.symbol.\(item.text)"
        return cell
    }
    func collectionView(_ collectionView: UICollectionView, willDisplay cell: UICollectionViewCell, forItemAt indexPath: IndexPath) {
        (cell as? SymbolCell)?.loadImage(priority: .visible)
        KeyboardEmojiImages.cancel(prefetches.removeValue(forKey: indexPath))
        KeyboardEmojiImages.cancel(lookahead.removeValue(forKey: indexPath))
    }
    func collectionView(_ collectionView: UICollectionView, didEndDisplaying cell: UICollectionViewCell, forItemAt indexPath: IndexPath) {
        // UIKit may display this prepared cell again without configuring it.
        // Retain its pixels until reuse/hide, especially for fast reversals.
        (cell as? SymbolCell)?.cancelImage()
    }
    func collectionView(_ collectionView: UICollectionView, prefetchItemsAt indexPaths: [IndexPath]) {
        for path in indexPaths where locations[path.section].mode == .emoji {
            if let token = prefetches[path], KeyboardEmojiImages.isPending(token) { continue }
            let values = items(in: path.section)
            guard path.item < values.count else { continue }
            prefetches[path] = KeyboardEmojiImages.request(values[path.item].text, scale: window?.screen.scale ?? traitCollection.displayScale)
        }
    }
    func collectionView(_ collectionView: UICollectionView, cancelPrefetchingForItemsAt indexPaths: [IndexPath]) {
        for path in indexPaths { KeyboardEmojiImages.cancel(prefetches.removeValue(forKey: path)) }
    }
    override var isHidden: Bool {
        didSet {
            if isHidden {
                cancelPrefetches()
                cells.allObjects.forEach { $0.releaseImage() }
            } else {
                collection.visibleCells.compactMap { $0 as? SymbolCell }.forEach { $0.loadImage(priority: .visible) }
                prepareAhead()
            }
        }
    }
    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        guard !collection.isDragging, !collection.isDecelerating else { return }
        let text = items(in: indexPath.section)[indexPath.item].text
        onSelect?(text)
        if locations[indexPath.section].mode == .emoji { onEmojiUse?(text) }
        collectionView.deselectItem(at: indexPath, animated: false)
    }

    /// Calculate only attributes intersecting the viewport. No per-catalog
    /// cell, bitmap or layout-attribute cache; UIKit reuses the visible cells.
    private final class SymbolLayout: UICollectionViewLayout {
        struct Section { let x: CGFloat; let width: CGFloat; let count: Int }
        struct Anchor { let path: IndexPath; let fraction: CGFloat }
        var itemWidths = [CGFloat]()
        var compact = false
        private(set) var sections = [Section]()
        private var rows = 1
        private var rowStride: CGFloat = 44
        private var cellHeight: CGFloat = 40
        private var topInset: CGFloat = 4
        private var size = CGSize.zero
        override func prepare() {
            guard let collectionView, itemWidths.count == collectionView.numberOfSections else { return }
            let height = collectionView.bounds.height
            rows = compact ? max(1, Int((height - 4) / 44)) : 5
            cellHeight = min(40, max(1, (height - 4) / CGFloat(rows)))
            topInset = min(2, max(0, (height - cellHeight) / 2))
            rowStride = rows > 1 ? max(0, (height - 2 * topInset - cellHeight) / CGFloat(rows - 1)) : 0
            var x: CGFloat = 0
            sections = (0..<collectionView.numberOfSections).map { section in
                let count = collectionView.numberOfItems(inSection: section)
                let columns = max(1, (count + rows - 1) / rows)
                let width = CGFloat(columns) * (itemWidths[section] + 4) - 4 + 12
                defer { x += width }
                return Section(x: x, width: width, count: count)
            }
            let trailing = max(0, collectionView.bounds.width - (sections.last?.width ?? 0))
            size = CGSize(width: max(collectionView.bounds.width, x + trailing), height: collectionView.bounds.height)
        }
        override var collectionViewContentSize: CGSize { size }
        func start(of section: Int) -> CGFloat { sections.indices.contains(section) ? sections[section].x : 0 }
        func section(at x: CGFloat) -> Int { sections.lastIndex { $0.x <= x } ?? 0 }
        func anchor(at x: CGFloat) -> Anchor? {
            guard !sections.isEmpty else { return nil }
            let section = section(at: x), stride = itemWidths[section] + 4
            let progress = max(0, (x - start(of: section)) / stride)
            return Anchor(path: IndexPath(item: min(max(0, sections[section].count - 1), Int(progress) * rows), section: section), fraction: progress - floor(progress))
        }
        func offset(for anchor: Anchor) -> CGFloat {
            start(of: anchor.path.section) + (CGFloat(anchor.path.item / rows) + anchor.fraction) * (itemWidths[anchor.path.section] + 4)
        }
        override func shouldInvalidateLayout(forBoundsChange newBounds: CGRect) -> Bool { newBounds.size != collectionView?.bounds.size }
        override func layoutAttributesForItem(at path: IndexPath) -> UICollectionViewLayoutAttributes? {
            guard sections.indices.contains(path.section), path.item < sections[path.section].count else { return nil }
            let attributes = UICollectionViewLayoutAttributes(forCellWith: path)
            attributes.frame = CGRect(x: start(of: path.section) + 6 + CGFloat(path.item / rows) * (itemWidths[path.section] + 4),
                y: topInset + CGFloat(path.item % rows) * rowStride, width: itemWidths[path.section], height: cellHeight)
            return attributes
        }
        override func layoutAttributesForElements(in rect: CGRect) -> [UICollectionViewLayoutAttributes]? {
            var attributes = [UICollectionViewLayoutAttributes]()
            for (section, info) in sections.enumerated() where info.x + info.width >= rect.minX && info.x <= rect.maxX {
                let stride = itemWidths[section] + 4
                let first = max(0, Int(floor((rect.minX - info.x - 6) / stride))) * rows
                let last = min(info.count, (max(0, Int(ceil((rect.maxX - info.x - 6) / stride))) + 1) * rows)
                if first < last {
                    for item in first..<last {
                        if let value = layoutAttributesForItem(at: IndexPath(item: item, section: section)), value.frame.intersects(rect) { attributes.append(value) }
                    }
                }
            }
            return attributes
        }
    }
    private final class SymbolCell: UICollectionViewCell {
        let label = UILabel()
        let emoji = UIImageView()
        private var imageRequest: UUID?
        private var identity = UUID()
        private var text: String?
        private var scale: CGFloat = 1
        func configure(_ text: String, emoji isEmoji: Bool, scale: CGFloat) {
            cancelImage(); identity = UUID(); self.text = isEmoji ? text : nil; self.scale = max(1, scale)
            emoji.image = nil; emoji.isHidden = !isEmoji
            label.isHidden = isEmoji
            // Even hidden UILabels measure assigned text and can fill the
            // native color-glyph cache. Pending bitmaps keep label.text nil.
            label.text = isEmoji ? nil : text
            loadImage()
        }
        func loadImage(priority: KeyboardEmojiImages.Priority = .prepared) {
            guard let text, emoji.image == nil else { return }
            if let image = KeyboardEmojiImages.cachedImage(text, scale: scale) {
                cancelImage(); applyImage(image, text: text); return
            }
            if priority == .visible {
                cancelImage()
                applyImage(KeyboardEmojiImages.displayImage(text, scale: scale), text: text)
                return
            }
            if let imageRequest, KeyboardEmojiImages.isPending(imageRequest) {
                KeyboardEmojiImages.promote(imageRequest, to: priority); return
            }
            imageRequest = nil
            let expected = identity, epoch = KeyboardEmojiImages.cacheGeneration
            imageRequest = KeyboardEmojiImages.request(text, scale: scale, priority: priority) { [weak self] image in
                guard let self, self.identity == expected else { return }
                self.imageRequest = nil
                guard epoch == KeyboardEmojiImages.cacheGeneration else { return }
                self.applyImage(image, text: text)
            }
        }
        private func applyImage(_ image: UIImage?, text: String) {
            emoji.image = image
            label.text = image == nil ? text : nil
            label.isHidden = image != nil; emoji.isHidden = image == nil
        }
        func cancelImage() { KeyboardEmojiImages.cancel(imageRequest); imageRequest = nil }
        func releaseImage() { cancelImage(); identity = UUID(); emoji.image = nil }
        override func prepareForReuse() {
            super.prepareForReuse(); cancelImage(); identity = UUID(); text = nil
            label.text = nil; emoji.image = nil
        }
        override init(frame: CGRect) {
            super.init(frame: frame)
            label.textAlignment = .center; label.adjustsFontSizeToFitWidth = true; label.minimumScaleFactor = 0.5
            contentView.addSubview(label); contentView.layer.cornerRadius = 6
            emoji.contentMode = .scaleAspectFit; contentView.addSubview(emoji)
            isAccessibilityElement = true; accessibilityTraits = .button
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override func layoutSubviews() {
            super.layoutSubviews(); label.frame = contentView.bounds.insetBy(dx: 3, dy: 2)
            let size = min(36, contentView.bounds.width, contentView.bounds.height)
            emoji.frame = CGRect(x: (contentView.bounds.width - size) / 2,
                y: (contentView.bounds.height - size) / 2, width: size, height: size)
        }
    }
}
