import UIKit

/// One continuous horizontal collection across all symbol categories.
///
/// Portrait: the category bar on top, the content, then a bottom bar with
/// ABC (back to the keyboard), the 表情 / 颜文字 / 符号 slider, search
/// (emoji only) and delete. Symbols and kaomoji are keys, a screen at a time,
/// read row by row. Landscape keeps every control in the toolbar row.
final class KeyboardSymbolPanel: UIView, UICollectionViewDataSource, UICollectionViewDelegate, UICollectionViewDataSourcePrefetching {
    enum Mode: Int, CaseIterable { case emoji, kaomoji, symbols }
    var onSelect: ((String) -> Void)?
    var onClose: (() -> Void)?
    var onFeedback: (() -> Void)?
    /// An emoji was inserted; the keyboard records it for the recent category.
    var onEmojiUse: ((String) -> Void)?
    var onSearch: (() -> Void)?
    /// The delete key; repeats while held.
    var onDelete: (() -> Void)?
    /// The symbols' common page follows the input language.
    var chineseSymbols = false {
        didSet {
            guard chineseSymbols != oldValue else { return }
            symbolGroups = KeyboardSymbolCatalog.symbols(chinese: chineseSymbols)
            cancelPrefetches(); collection.reloadData()
            layout.specs = specs(); layout.invalidateLayout()
            if displayedMode == .symbols { rebuildCategories(for: .symbols) }
            headerSelection = nil; setNeedsLayout()
        }
    }
    private var symbolGroups = KeyboardSymbolCatalog.symbols(chinese: false)
    /// Recently used emoji, shown as the first emoji category when not empty.
    var recents: [String] = [] {
        didSet {
            guard recents != oldValue else { return }
            let current = locations[selectedSection]
            recentItems = recents.filter { !KeyboardEmojiAvailability.isRegionallyHidden($0) }
                .map { KeyboardSymbolCatalog.Item(text: $0, name: KeyboardSymbolCatalog.emojiNames[$0] ?? $0) }
            cancelPrefetches()
            locations = Self.locations(hasRecents: !recentItems.isEmpty)
            selectedSection = locations.firstIndex { $0.mode == current.mode && $0.group == current.group } ?? 0
            headerSelection = nil
            rebuildCategories(for: displayedMode)
            layout.specs = specs()
            collection.reloadData(); layout.invalidateLayout()
            if collection.bounds.width > 0 { showSection(selectedSection, feedback: false) }
        }
    }
    var compact = false { didSet { if oldValue != compact { setNeedsLayout() } } }
    /// The docked iPad keyboard: more rows, larger cells.
    var regular = false { didSet { if oldValue != regular { setNeedsLayout() } } }
    private let modes = UISegmentedControl(items: [String(localized: "表情"), String(localized: "颜文字"), String(localized: "符号")])
    private let close = UIButton(type: .system)
    private let search = UIButton(type: .system)
    private let delete = UIButton(type: .system)
    private var deleteRepeat: Timer?
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
        case .symbols: KeyboardSymbolCatalog.symbols(chinese: false)
        }
    }
    private func groups(for mode: Mode) -> [KeyboardSymbolCatalog.Group] {
        mode == .symbols ? symbolGroups : Self.groups(for: mode)
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
        return location.mode == .emoji ? emojiItems[location.group] ?? [] : groups(for: location.mode)[location.group].items
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
        // Portrait's bottom bar names the way back like the keyboard's own
        // 123/ABC key; landscape swaps in a chevron. Set from the start so
        // the opening frame never shows a default-tinted title.
        close.setTitle("ABC", for: .normal)
        close.setTitleColor(KeyboardPalette.text, for: .normal)
        close.accessibilityLabel = String(localized: "返回键盘")
        close.titleLabel?.font = .systemFont(ofSize: 16, weight: .medium)
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
        delete.setImage(UIImage(systemName: "delete.left", withConfiguration: UIImage.SymbolConfiguration(pointSize: 17, weight: .regular)), for: .normal)
        delete.accessibilityLabel = String(localized: "删除")
        delete.accessibilityIdentifier = "vime.symbols.delete"
        delete.addAction(UIAction { [weak self] _ in self?.beginDeleting() }, for: .touchDown)
        delete.addAction(UIAction { [weak self] _ in self?.endDeleting() }, for: [.touchUpInside, .touchUpOutside, .touchCancel])
        categories.showsHorizontalScrollIndicator = false
        categories.delegate = self
        categories.accessibilityIdentifier = "vime.symbols.categories"
        categoryIndicator.accessibilityIdentifier = "vime.symbols.category.indicator"
        categoryIndicator.isUserInteractionEnabled = false
        categoryIndicator.layer.cornerRadius = 8
        categories.addSubview(categoryIndicator)
        for view in [modes, close, search, delete, categories, viewport] { addSubview(view) }
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
    private func beginDeleting() {
        endDeleting()
        onFeedback?(); onDelete?()
        deleteRepeat = Timer.scheduledTimer(withTimeInterval: 0.45, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.deleteRepeat = Timer.scheduledTimer(withTimeInterval: 0.09, repeats: true) { [weak self] _ in
                    MainActor.assumeIsolated { self?.onDelete?() }
                }
            }
        }
    }
    private func endDeleting() { deleteRepeat?.invalidate(); deleteRepeat = nil }
    func selectMode(_ mode: Mode) {
        if locations[selectedSection].mode != mode { showSection(firstSection(of: mode)) }
    }

    /// The bottom bar's height and the gap below it.
    static let bottomBarHeight: CGFloat = 42
    static let bottomGap: CGFloat = 4

    override func layoutSubviews() {
        super.layoutSubviews()
        let anchor = layout.anchor(at: collection.contentOffset.x)
        let oldSize = collection.bounds.size
        let top = KeyboardMetrics.toolbarTopInset
        let metrics = KeyboardMetrics(width: bounds.width, compact: compact, showsFooter: false)
        let gridTop: CGFloat
        let gridBottom: CGFloat
        if compact {
            if close.title(for: .normal) != nil {
                close.setTitle(nil, for: .normal)
                close.setImage(UIImage(systemName: "chevron.up"), for: .normal)
            }
            close.frame = metrics.trailingToolbarFrame(index: 0)
            search.frame = metrics.trailingToolbarFrame(index: 1)
            close.layer.cornerRadius = metrics.toolbarButtonDiameter / 2
            search.layer.cornerRadius = close.layer.cornerRadius
            close.backgroundColor = KeyboardPalette.key; search.backgroundColor = KeyboardPalette.key
            close.tintColor = .secondaryLabel; search.tintColor = .secondaryLabel
            search.isHidden = false; delete.isHidden = true
            modes.frame = CGRect(x: metrics.contentLeft, y: top,
                width: min(320, search.frame.minX - KeyboardMetrics.toolbarGap - metrics.contentLeft), height: metrics.toolbarButtonDiameter)
            categories.frame = CGRect(x: metrics.contentLeft, y: metrics.headerHeight, width: metrics.contentWidth, height: 28)
            gridTop = categories.frame.maxY + 4
            gridBottom = bounds.height
        } else {
            // Bottom bar: ABC, the mode slider, search (emoji), delete.
            let left = metrics.contentLeft, right = metrics.contentLeft + metrics.contentWidth
            let barY = bounds.height - Self.bottomGap - Self.bottomBarHeight
            let key = Self.bottomBarHeight, wide = max(56, key * 1.35)
            if close.title(for: .normal) != "ABC" {
                close.setImage(nil, for: .normal)
                close.setTitle("ABC", for: .normal)
            }
            close.frame = CGRect(x: left, y: barY, width: wide, height: key)
            delete.frame = CGRect(x: right - wide, y: barY, width: wide, height: key)
            search.frame = CGRect(x: delete.frame.minX - 6 - key, y: barY, width: key, height: key)
            search.isHidden = displayedMode != .emoji; delete.isHidden = false
            let modesRight = search.isHidden ? delete.frame.minX : search.frame.minX
            modes.frame = CGRect(x: close.frame.maxX + 8, y: barY + 3, width: max(0, modesRight - 8 - close.frame.maxX - 8), height: key - 6)
            for button in [close, search, delete] {
                button.backgroundColor = KeyboardPalette.utility
                button.tintColor = KeyboardPalette.text
                button.setTitleColor(KeyboardPalette.text, for: .normal)
                button.layer.cornerRadius = 8
            }
            categories.frame = CGRect(x: 0, y: top, width: bounds.width, height: 30)
            gridTop = categories.frame.maxY + 2
            gridBottom = barY - 4
        }
        layoutCategories()
        layingOut = true
        viewport.frame = CGRect(x: compact ? metrics.contentLeft : 0, y: gridTop,
            width: compact ? metrics.contentWidth : bounds.width, height: max(0, gridBottom - gridTop))
        collection.frame = viewport.bounds
        loading.center = CGPoint(x: viewport.bounds.midX, y: viewport.bounds.midY)
        if oldSize != collection.bounds.size || layout.regular != regular || layout.compact != compact {
            layout.compact = compact
            layout.regular = regular
            layout.specs = specs()
            layout.invalidateLayout(); collection.layoutIfNeeded()
            let offset = anchor.map { layout.offset(for: $0) } ?? layout.start(of: selectedSection)
            collection.setContentOffset(CGPoint(x: offset, y: 0), animated: false)
        }
        layingOut = false
        syncHeaderToScrolling()
        prepareAhead()
    }
    /// Emoji fill columns top to bottom; symbols and kaomoji are keys, a
    /// screen of rows at a time (landscape: columns, as emoji).
    private func specs() -> [SymbolLayout.Spec] {
        let width = collection.bounds.width
        return locations.map { location in
            func spec(columns: Int, gap: CGFloat, rows: Int?) -> SymbolLayout.Spec {
                .init(width: max(1, floor((width - 12 - CGFloat(columns - 1) * gap) / CGFloat(columns))), gap: gap,
                      rows: rows, columns: rows == nil ? nil : columns)
            }
            switch location.mode {
            case .emoji:
                return spec(columns: max(5, Int((width - 8) / (42 * (regular ? 1.3 : 1)))), gap: 4, rows: nil)
            case .kaomoji:
                // iPad keeps continuous columns: a wide page of a short
                // group would leave most of the panel empty.
                return compact || regular ? spec(columns: max(2, Int(width / 145)), gap: 4, rows: nil)
                    : spec(columns: 3, gap: 6, rows: 4)
            case .symbols:
                return compact || regular ? spec(columns: max(5, Int((width - 8) / (48 * (regular ? 1.3 : 1)))), gap: 4, rows: nil)
                    : spec(columns: 7, gap: 6, rows: 4)
            }
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
        let titles = recent + groups(for: mode).enumerated().map { ($0, KeyboardSymbolCatalog.title(for: $1.name)) }
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
        let transition = min(layout.sections[lower].width, layout.specs[lower].width + layout.specs[lower].gap)
        let fraction: CGFloat = lower == upper ? 0 : max(0, min(1, (offset - layout.start(of: upper) + transition) / transition))
        let previewSection = fraction < 0.5 ? lower : upper
        let preview = locations[previewSection]
        loading.isHidden = preview.mode != .emoji || !loading.isAnimating
        selectedSection = previewSection
        if displayedMode != preview.mode { rebuildCategories(for: preview.mode); setNeedsLayout() }
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
        modes.selectedSegmentTintColor = compact ? KeyboardPalette.utility : KeyboardPalette.key
        modes.backgroundColor = compact ? nil : KeyboardPalette.utility
        setNeedsLayout()
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
        cell.label.font = .systemFont(ofSize: mode == .kaomoji ? (compact ? 16 : 17) : mode == .symbols ? (compact ? 23 : 21) : 29)
        cell.contentView.backgroundColor = mode == .emoji ? .clear : KeyboardPalette.key
        cell.keyStyle = mode != .emoji && !compact
        // The character itself: VoiceOver names emoji in the user's language,
        // where the catalog only has English Unicode names.
        cell.accessibilityLabel = item.text
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
    ///
    /// A section without its own `rows` fills columns top to bottom (emoji);
    /// one with them is screens of `columns` × `rows` keys, each read row by row.
    final class SymbolLayout: UICollectionViewLayout {
        struct Spec { let width: CGFloat; let gap: CGFloat; let rows: Int?; let columns: Int? }
        struct Section {
            let x: CGFloat; let width: CGFloat; let count: Int
            let rows: Int; let cellHeight: CGFloat; let rowStride: CGFloat; let top: CGFloat
        }
        /// A column of a section and how far into it, kept across size changes.
        struct Anchor { let section: Int; let column: CGFloat }
        var specs = [Spec]()
        var compact = false
        var regular = false
        private(set) var sections = [Section]()
        private var size = CGSize.zero
        override func prepare() {
            guard let collectionView, specs.count == collectionView.numberOfSections else { return }
            let height = collectionView.bounds.height
            let defaultRows = compact ? max(1, Int((height - 4) / 44)) : regular ? max(5, Int((height - 4) / 54)) : 5
            var x: CGFloat = 0
            sections = (0..<collectionView.numberOfSections).map { section in
                let count = collectionView.numberOfItems(inSection: section)
                let spec = specs[section]
                let rows = spec.rows ?? defaultRows
                let cellHeight: CGFloat, rowStride: CGFloat, top: CGFloat
                if spec.rows != nil {
                    // Keys: the keyboard's spacing, centred in the height.
                    let rowGap: CGFloat = 8
                    cellHeight = max(1, min(regular ? 56 : 46, (height - 6 - CGFloat(rows - 1) * rowGap) / CGFloat(rows)))
                    rowStride = cellHeight + rowGap
                    top = max(0, (height - CGFloat(rows) * cellHeight - CGFloat(rows - 1) * rowGap) / 2)
                } else {
                    cellHeight = min(regular ? 48 : 40, max(1, (height - 4) / CGFloat(rows)))
                    top = min(2, max(0, (height - cellHeight) / 2))
                    rowStride = rows > 1 ? max(0, (height - 2 * top - cellHeight) / CGFloat(rows - 1)) : 0
                }
                let columns = Self.columns(count: count, rows: rows, spec: spec)
                let width = CGFloat(columns) * (spec.width + spec.gap) - spec.gap + 12
                defer { x += width }
                return Section(x: x, width: width, count: count, rows: rows, cellHeight: cellHeight, rowStride: rowStride, top: top)
            }
            let trailing = max(0, collectionView.bounds.width - (sections.last?.width ?? 0))
            size = CGSize(width: max(collectionView.bounds.width, x + trailing), height: collectionView.bounds.height)
        }
        private static func columns(count: Int, rows: Int, spec: Spec) -> Int {
            guard let perRow = spec.columns else { return max(1, (count + rows - 1) / rows) }
            let page = perRow * rows, full = count / page, rest = count % page
            return max(1, full * perRow + min(perRow, rest))
        }
        override var collectionViewContentSize: CGSize { size }
        func start(of section: Int) -> CGFloat { sections.indices.contains(section) ? sections[section].x : 0 }
        func section(at x: CGFloat) -> Int { sections.lastIndex { $0.x <= x } ?? 0 }
        private func stride(_ section: Int) -> CGFloat { specs[section].width + specs[section].gap }
        func anchor(at x: CGFloat) -> Anchor? {
            guard !sections.isEmpty, sections.count == specs.count else { return nil }
            let section = section(at: x)
            return Anchor(section: section, column: max(0, (x - start(of: section)) / stride(section)))
        }
        func offset(for anchor: Anchor) -> CGFloat {
            guard sections.indices.contains(anchor.section) else { return 0 }
            let spec = specs[anchor.section]
            // A screen of keys stays whole: snap to its first column.
            let column = spec.columns.map { CGFloat(Int(anchor.column) / $0 * $0) } ?? anchor.column
            return start(of: anchor.section) + column * stride(anchor.section)
        }
        /// The column and row of `item` in its section.
        private func position(of item: Int, in section: Int) -> (column: Int, row: Int) {
            let rows = sections[section].rows
            guard let perRow = specs[section].columns else { return (item / rows, item % rows) }
            let page = perRow * rows, index = item % page
            return (item / page * perRow + index % perRow, index / perRow)
        }
        private func item(column: Int, row: Int, in section: Int) -> Int? {
            let rows = sections[section].rows
            let item: Int
            if let perRow = specs[section].columns {
                item = column / perRow * perRow * rows + row * perRow + column % perRow
            } else { item = column * rows + row }
            return item < sections[section].count ? item : nil
        }
        override func shouldInvalidateLayout(forBoundsChange newBounds: CGRect) -> Bool { newBounds.size != collectionView?.bounds.size }
        override func layoutAttributesForItem(at path: IndexPath) -> UICollectionViewLayoutAttributes? {
            guard sections.indices.contains(path.section), path.item < sections[path.section].count else { return nil }
            let info = sections[path.section], (column, row) = position(of: path.item, in: path.section)
            let attributes = UICollectionViewLayoutAttributes(forCellWith: path)
            attributes.frame = CGRect(x: info.x + 6 + CGFloat(column) * stride(path.section),
                y: info.top + CGFloat(row) * info.rowStride, width: specs[path.section].width, height: info.cellHeight)
            return attributes
        }
        override func layoutAttributesForElements(in rect: CGRect) -> [UICollectionViewLayoutAttributes]? {
            var attributes = [UICollectionViewLayoutAttributes]()
            for (section, info) in sections.enumerated() where info.x + info.width >= rect.minX && info.x <= rect.maxX {
                let stride = stride(section)
                let first = max(0, Int(floor((rect.minX - info.x - 6) / stride)))
                let last = max(0, Int(ceil((rect.maxX - info.x - 6) / stride)))
                guard first <= last else { continue }
                for column in first...last {
                    for row in 0..<info.rows {
                        guard let item = item(column: column, row: row, in: section),
                              let value = layoutAttributesForItem(at: IndexPath(item: item, section: section)),
                              value.frame.intersects(rect) else { continue }
                        attributes.append(value)
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
        /// A key like the keyboard's: rounded, with its bottom shadow.
        var keyStyle = false {
            didSet {
                contentView.layer.cornerRadius = keyStyle ? 7 : 6
                layer.shadowOpacity = keyStyle ? 0.22 : 0
            }
        }
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
            layer.shadowColor = UIColor.black.cgColor; layer.shadowOffset = CGSize(width: 0, height: 1)
            layer.shadowRadius = 0; layer.shadowOpacity = 0
            emoji.contentMode = .scaleAspectFit; contentView.addSubview(emoji)
            isAccessibilityElement = true; accessibilityTraits = .button
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override func layoutSubviews() {
            super.layoutSubviews(); label.frame = contentView.bounds.insetBy(dx: 3, dy: 2)
            layer.shadowPath = keyStyle ? UIBezierPath(roundedRect: bounds, cornerRadius: 7).cgPath : nil
            let size = min(36, contentView.bounds.width, contentView.bounds.height)
            emoji.frame = CGRect(x: (contentView.bounds.width - size) / 2,
                y: (contentView.bounds.height - size) / 2, width: size, height: size)
        }
    }
}
