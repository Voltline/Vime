import UIKit

/// The emoji panel with its kaomoji, or the symbol panel.
///
/// The emoji key opens emoji, with kaomoji a slider away; the symbol key
/// opens symbols alone. Emoji scroll continuously across their categories;
/// kaomoji and symbols are pages of keys, read row by row. Portrait: the
/// category bar on top, the content, then a bottom bar with ABC (back to
/// the keyboard), the 表情 / 颜文字 slider and search (emoji panel only),
/// and delete. Landscape keeps every control in the toolbar row.
final class KeyboardSymbolPanel: UIView, UICollectionViewDataSource, UICollectionViewDelegate, UICollectionViewDataSourcePrefetching {
    enum Mode: Int, CaseIterable { case emoji, kaomoji, symbols }
    var onSelect: ((String) -> Void)?
    var onClose: (() -> Void)?
    var onFeedback: (() -> Void)?
    /// An emoji was inserted; the keyboard records it for emoji search.
    var onEmojiUse: ((String) -> Void)?
    var onSearch: (() -> Void)?
    /// The delete key; repeats while held.
    var onDelete: (() -> Void)?
    /// The symbols' common page follows the input language.
    var chineseSymbols = false {
        didSet {
            guard chineseSymbols != oldValue else { return }
            symbolGroups = KeyboardSymbolCatalog.symbols(chinese: chineseSymbols)
            if displayedMode == .symbols { reload(keeping: true) }
        }
    }
    private var symbolGroups = KeyboardSymbolCatalog.symbols(chinese: false)
    var compact = false { didSet { if oldValue != compact { setNeedsLayout() } } }
    /// The docked iPad keyboard: more rows, larger cells.
    var regular = false { didSet { if oldValue != regular { setNeedsLayout() } } }
    /// The emoji panel's slider; the symbol panel has none.
    private static let sliderModes: [Mode] = [.emoji, .kaomoji]
    private let modes = UISegmentedControl(items: [String(localized: "表情"), String(localized: "颜文字")])
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
    private(set) var displayedMode: Mode = .emoji
    private var selectedSection = 0
    /// Where the next layout puts the content: a section's start.
    private var pendingSection: Int?
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
    /// The displayed mode's categories.
    private var groupsShown: [Int] = KeyboardSymbolCatalog.emojiGroups.indices.map { $0 }
    private func groups(for mode: Mode) -> [KeyboardSymbolCatalog.Group] {
        switch mode {
        case .emoji: KeyboardSymbolCatalog.emojiGroups
        case .kaomoji: KeyboardSymbolCatalog.kaomoji
        case .symbols: symbolGroups
        }
    }
    private func items(in section: Int) -> [KeyboardSymbolCatalog.Item] {
        guard groupsShown.indices.contains(section) else { return [] }
        let group = groupsShown[section]
        return displayedMode == .emoji ? emojiItems[group] ?? [] : groups(for: displayedMode)[group].items
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
            guard let self, Self.sliderModes.indices.contains(self.modes.selectedSegmentIndex) else { return }
            let mode = Self.sliderModes[self.modes.selectedSegmentIndex]
            guard mode != self.displayedMode else { return }
            self.collection.setContentOffset(self.collection.contentOffset, animated: false)
            self.onFeedback?()
            self.show(mode)
        }, for: .valueChanged)
        // Portrait's bottom bar names the way back like the keyboard's own
        // 123/ABC key, in the accent like the number pad's way back;
        // landscape swaps in a chevron. Set from the start so the opening
        // frame never shows a default-tinted title.
        close.setTitle("ABC", for: .normal)
        close.setTitleColor(.white, for: .normal)
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
        // ABC and delete sit on the grid's last row in the symbol panel, so they stay above it.
        for view in [categories, viewport, modes, close, search, delete] { addSubview(view) }
        viewport.addSubview(collection); viewport.addSubview(loading)
        loading.hidesWhenStopped = true; loading.startAnimating()
        rebuildCategories()
        registerForTraitChanges(UITraitCollection.systemTraitsAffectingColorAppearance) {
            (panel: KeyboardSymbolPanel, _: UITraitCollection) in
            panel.traitCollection.performAsCurrent { panel.applyTheme() }
        }
        registerForTraitChanges([UITraitDisplayScale.self]) {
            (panel: KeyboardSymbolPanel, _: UITraitCollection) in panel.applyTheme()
        }
        let emojiGroups = KeyboardSymbolCatalog.emojiGroups
        for (index, group) in emojiGroups.enumerated() {
            KeyboardEmojiAvailability.load(group) { [weak self] items in
                guard let self else { return }
                self.emojiItems[index] = items
                if self.emojiItems.count == emojiGroups.count {
                    self.loading.stopAnimating()
                    if self.displayedMode == .emoji { self.reload(keeping: true) }
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

    /// Opens on `mode` straight away, without feedback: the key that opened
    /// the panel already gave it. The same mode keeps its place.
    func selectMode(_ mode: Mode) {
        if mode != displayedMode { show(mode) }
    }

    /// Shows `mode`'s categories from the first.
    private func show(_ mode: Mode) {
        displayedMode = mode
        if let index = Self.sliderModes.firstIndex(of: mode), modes.selectedSegmentIndex != index {
            modes.selectedSegmentIndex = index
        }
        reload(keeping: false)
    }

    /// Reloads the displayed mode's categories, at the same one when `keeping`.
    private func reload(keeping: Bool) {
        let current = groupsShown.indices.contains(selectedSection) ? groupsShown[selectedSection] : nil
        cancelPrefetches()
        groupsShown = Array(groups(for: displayedMode).indices)
        selectedSection = keeping ? current.flatMap { groupsShown.firstIndex(of: $0) } ?? 0 : 0
        pendingSection = selectedSection
        headerSelection = nil; headerProgress = nil
        rebuildCategories()
        collection.isPagingEnabled = displayedMode != .emoji
        loading.isHidden = displayedMode != .emoji || !loading.isAnimating
        layout.specs = specs()
        collection.reloadData(); layout.invalidateLayout()
        setNeedsLayout()
        if collection.bounds.width > 0 { layoutIfNeeded() }
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
        // The emoji panel (emoji or kaomoji) has the slider and search.
        let emoji = displayedMode != .symbols
        let gridTop: CGFloat
        let gridBottom: CGFloat
        modes.isHidden = !emoji
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
            search.isHidden = !emoji; delete.isHidden = true
            let trailing = emoji ? search.frame.minX : close.frame.minX
            modes.frame = CGRect(x: metrics.contentLeft, y: top,
                width: min(320, trailing - KeyboardMetrics.toolbarGap - metrics.contentLeft), height: metrics.toolbarButtonDiameter)
            categories.frame = CGRect(x: metrics.contentLeft, y: metrics.headerHeight, width: metrics.contentWidth, height: 28)
            gridTop = categories.frame.maxY + 4
            gridBottom = bounds.height
        } else {
            // Bottom bar: ABC, the slider and search (emoji panel), and delete.
            let left = metrics.contentLeft, right = metrics.contentLeft + metrics.contentWidth
            let barY = bounds.height - Self.bottomGap - Self.bottomBarHeight
            // ABC is as wide as the number page's and reads alike.
            let key = Self.bottomBarHeight, wide = 59.8 * metrics.scale
            close.titleLabel?.font = KeyboardView.backKeyFont(compact: false, scale: metrics.scale)
            if close.title(for: .normal) != "ABC" {
                close.setImage(nil, for: .normal)
                close.setTitle("ABC", for: .normal)
            }
            close.frame = CGRect(x: left, y: barY, width: wide, height: key)
            delete.frame = CGRect(x: right - wide, y: barY, width: wide, height: key)
            search.frame = CGRect(x: delete.frame.minX - 6 - key, y: barY, width: key, height: key)
            search.isHidden = !emoji; delete.isHidden = false
            modes.frame = CGRect(x: close.frame.maxX + 8, y: barY + 3,
                width: max(0, search.frame.minX - 8 - close.frame.maxX - 8), height: key - 6)
            for button in [close, search, delete] {
                button.backgroundColor = KeyboardPalette.utility
                button.tintColor = KeyboardPalette.text
                button.setTitleColor(KeyboardPalette.text, for: .normal)
                button.layer.cornerRadius = 8
            }
            close.backgroundColor = KeyboardPalette.accent
            close.setTitleColor(.white, for: .normal)
            categories.frame = CGRect(x: 0, y: top, width: bounds.width, height: 30)
            gridTop = categories.frame.maxY + 2
            gridBottom = emoji ? barY - 4 : bounds.height - Self.bottomGap
        }
        layoutCategories()
        layingOut = true
        viewport.frame = CGRect(x: compact ? metrics.contentLeft : 0, y: gridTop,
            width: compact ? metrics.contentWidth : bounds.width, height: max(0, gridBottom - gridTop))
        collection.frame = viewport.bounds
        loading.center = CGPoint(x: viewport.bounds.midX, y: viewport.bounds.midY)
        let resized = oldSize != collection.bounds.size || layout.regular != regular || layout.compact != compact
        if resized || pendingSection != nil {
            layout.compact = compact
            layout.regular = regular
            layout.specs = specs()
            layout.invalidateLayout(); collection.layoutIfNeeded()
            let offset = pendingSection.map { layout.start(of: $0) }
                ?? anchor.map { layout.offset(for: $0) } ?? layout.start(of: selectedSection)
            if collection.bounds.width > 0 { pendingSection = nil }
            collection.setContentOffset(CGPoint(x: offset, y: 0), animated: false)
            previousOffset = offset
        }
        layingOut = false
        if !compact, !emoji {
            // The symbol panel: ABC and delete take the ends of the last row.
            collection.layoutIfNeeded()
            if let keys = layout.frameKeys() {
                close.frame = keys.leading.offsetBy(dx: viewport.frame.minX, dy: viewport.frame.minY)
                delete.frame = keys.trailing.offsetBy(dx: viewport.frame.minX, dy: viewport.frame.minY)
            }
        }
        syncHeaderToScrolling()
        prepareAhead()
    }
    /// Emoji fill columns top to bottom; symbols and kaomoji are pages of
    /// keys, read row by row.
    private func specs() -> [SymbolLayout.Spec] {
        let width = collection.bounds.width
        func spec(columns: Int, gap: CGFloat, rows: Int?, paged: Bool, framed: Bool = false) -> SymbolLayout.Spec {
            .init(width: max(1, floor((width - 12 - CGFloat(columns - 1) * gap) / CGFloat(columns))), gap: gap,
                  rows: rows, columns: paged ? columns : nil, paged: paged, framed: framed)
        }
        let one: SymbolLayout.Spec
        switch displayedMode {
        case .emoji:
            one = spec(columns: max(5, Int((width - 8) / (42 * (regular ? 1.3 : 1)))), gap: 4, rows: nil, paged: false)
        case .kaomoji:
            one = compact || regular ? spec(columns: max(2, Int(width / 145)), gap: 4, rows: nil, paged: true)
                : spec(columns: 3, gap: 6, rows: 4, paged: true)
        case .symbols:
            // Portrait has no bottom bar: ABC and delete end the last row.
            one = compact ? spec(columns: max(5, Int((width - 8) / 48)), gap: 4, rows: nil, paged: true)
                : regular ? spec(columns: max(5, Int((width - 8) / (48 * 1.3))), gap: 4, rows: nil, paged: true, framed: true)
                : spec(columns: 7, gap: 6, rows: 5, paged: true, framed: true)
        }
        return Array(repeating: one, count: groupsShown.count)
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
    private func rebuildCategories() {
        categoryButtons.forEach { $0.removeFromSuperview() }
        let all = groups(for: displayedMode)
        categoryButtons = groupsShown.enumerated().map { section, group in
            let button = UIButton(type: .system)
            button.setTitle(KeyboardSymbolCatalog.title(for: all[group].name), for: .normal)
            button.titleLabel?.font = .systemFont(ofSize: 14)
            button.accessibilityIdentifier = "vime.symbols.category.\(group)"
            button.addAction(UIAction { [weak self] _ in self?.showSection(section) }, for: .touchUpInside)
            categories.addSubview(button)
            return button
        }
        layoutCategories()
    }
    private func syncHeaderToScrolling() {
        let timing = KeyboardPerformance.start()
        defer { KeyboardPerformance.record(.symbolHeaderUpdate, since: timing) }
        guard !layingOut, !groupsShown.isEmpty, layout.sections.count == groupsShown.count else { return }
        let offset = max(0, collection.contentOffset.x)
        let lower = layout.section(at: offset), upper = min(lower + 1, groupsShown.count - 1)
        let step = layout.specs[lower].paged ? collection.bounds.width : layout.specs[lower].width + layout.specs[lower].gap
        let transition = max(1, min(layout.sections[lower].width, step))
        let fraction: CGFloat = lower == upper ? 0 : max(0, min(1, (offset - layout.start(of: upper) + transition) / transition))
        let preview = fraction < 0.5 ? lower : upper
        selectedSection = preview
        let progress = CGFloat(lower) + fraction
        if headerSelection != preview {
            headerSelection = preview
            for (index, button) in categoryButtons.enumerated() {
                let selected = index == preview
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
    private func showSection(_ section: Int) {
        selectedSection = section
        onFeedback?()
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
        guard !layingOut, !isHidden, displayedMode == .emoji, collection.bounds.width > 0, !layout.sections.isEmpty else { return }
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
            return attributes.filter { _ in displayedMode == .emoji }
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
    func numberOfSections(in collectionView: UICollectionView) -> Int { groupsShown.count }
    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int { items(in: section).count }
    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let timing = KeyboardPerformance.start()
        defer { KeyboardPerformance.record(.symbolCellConfiguration, since: timing) }
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: "symbol", for: indexPath) as! SymbolCell
        cells.add(cell)
        let item = items(in: indexPath.section)[indexPath.item], mode = displayedMode
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
        for path in indexPaths where displayedMode == .emoji {
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
                endDeleting()
                cancelPrefetches()
                cells.allObjects.forEach { $0.releaseImage() }
            } else {
                collection.visibleCells.compactMap { $0 as? SymbolCell }.forEach { $0.loadImage(priority: .visible) }
                prepareAhead()
            }
        }
    }
    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil { endDeleting() }
    }
    deinit { deleteRepeat?.invalidate() }
    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        guard !collection.isDragging, !collection.isDecelerating else { return }
        let text = items(in: indexPath.section)[indexPath.item].text
        onSelect?(text)
        if displayedMode == .emoji { onEmojiUse?(text) }
        collectionView.deselectItem(at: indexPath, animated: false)
    }

    /// Calculate only attributes intersecting the viewport. No per-catalog
    /// cell, bitmap or layout-attribute cache; UIKit reuses the visible cells.
    ///
    /// A section without `rows` and not paged fills columns top to bottom
    /// (emoji); a paged one is pages of `columns` × `rows` keys, each the
    /// collection's width and read row by row.
    final class SymbolLayout: UICollectionViewLayout {
        struct Spec {
            let width: CGFloat; let gap: CGFloat; let rows: Int?; let columns: Int?; var paged = false
            /// The last row of each page leaves its first and last key to the
            /// panel's ABC and delete.
            var framed = false
        }
        struct Section {
            let x: CGFloat; let width: CGFloat; let count: Int
            let rows: Int; let columns: Int; let cellHeight: CGFloat; let rowStride: CGFloat; let top: CGFloat
            /// A page's width; zero for continuous columns.
            let page: CGFloat; let inset: CGFloat
            let framed: Bool
            /// Keys on a page: the last row gives up its two ends when framed.
            var perPage: Int { columns * rows - (framed ? 2 : 0) }
        }
        /// A column (a page, when paged) of a section and how far into it,
        /// kept across size changes.
        struct Anchor { let section: Int; let column: CGFloat }
        var specs = [Spec]()
        var compact = false
        var regular = false
        private(set) var sections = [Section]()
        private var size = CGSize.zero
        override func prepare() {
            guard let collectionView, specs.count == collectionView.numberOfSections else { sections = []; return }
            let height = collectionView.bounds.height, pageWidth = collectionView.bounds.width
            let defaultRows = compact ? max(1, Int((height - 4) / 44)) : regular ? max(5, Int((height - 4) / 54)) : 5
            var x: CGFloat = 0
            sections = (0..<collectionView.numberOfSections).map { section in
                let count = collectionView.numberOfItems(inSection: section)
                let spec = specs[section]
                let rows = spec.rows ?? defaultRows
                let cellHeight: CGFloat, rowStride: CGFloat, top: CGFloat
                if spec.rows != nil || spec.paged {
                    // Keys: the keyboard's spacing, centred in the height.
                    let rowGap: CGFloat = compact ? 6 : 8
                    cellHeight = max(1, min(regular ? 56 : 46, (height - 6 - CGFloat(rows - 1) * rowGap) / CGFloat(rows)))
                    rowStride = cellHeight + rowGap
                    top = max(0, (height - CGFloat(rows) * cellHeight - CGFloat(rows - 1) * rowGap) / 2)
                } else {
                    cellHeight = min(regular ? 48 : 40, max(1, (height - 4) / CGFloat(rows)))
                    top = min(2, max(0, (height - cellHeight) / 2))
                    rowStride = rows > 1 ? max(0, (height - 2 * top - cellHeight) / CGFloat(rows - 1)) : 0
                }
                let width: CGFloat, columns: Int, inset: CGFloat, page: CGFloat
                if spec.paged {
                    columns = max(1, spec.columns ?? 1)
                    let perPage = max(1, columns * rows - (spec.framed ? 2 : 0))
                    let pages = max(1, (count + perPage - 1) / perPage)
                    page = max(1, pageWidth)
                    width = CGFloat(pages) * page
                    inset = max(0, (page - CGFloat(columns) * (spec.width + spec.gap) + spec.gap) / 2)
                } else {
                    columns = max(1, (count + rows - 1) / rows)
                    width = CGFloat(columns) * (spec.width + spec.gap) - spec.gap + 12
                    inset = 6; page = 0
                }
                defer { x += width }
                return Section(x: x, width: width, count: count, rows: rows, columns: columns,
                               cellHeight: cellHeight, rowStride: rowStride, top: top, page: page, inset: inset,
                               framed: spec.paged && spec.framed)
            }
            let trailing = max(0, pageWidth - (sections.last?.width ?? 0))
            size = CGSize(width: max(pageWidth, x + trailing), height: height)
        }
        override var collectionViewContentSize: CGSize { size }
        func start(of section: Int) -> CGFloat { sections.indices.contains(section) ? sections[section].x : 0 }
        func section(at x: CGFloat) -> Int { sections.lastIndex { $0.x <= x } ?? 0 }
        private func stride(_ section: Int) -> CGFloat {
            sections[section].page > 0 ? sections[section].page : specs[section].width + specs[section].gap
        }
        func anchor(at x: CGFloat) -> Anchor? {
            guard !sections.isEmpty, sections.count == specs.count else { return nil }
            let section = section(at: x)
            return Anchor(section: section, column: max(0, (x - start(of: section)) / stride(section)))
        }
        func offset(for anchor: Anchor) -> CGFloat {
            guard sections.indices.contains(anchor.section) else { return 0 }
            // A page stays whole: snap to its start.
            let column = sections[anchor.section].page > 0 ? anchor.column.rounded(.down) : anchor.column
            return start(of: anchor.section) + column * stride(anchor.section)
        }
        /// The keys a framed page leaves free, in the collection's visible
        /// coordinates: the last row's first and last.
        func frameKeys() -> (leading: CGRect, trailing: CGRect)? {
            guard let info = sections.first, info.framed, let spec = specs.first else { return nil }
            let y = info.top + CGFloat(info.rows - 1) * info.rowStride
            let leading = CGRect(x: info.inset, y: y, width: spec.width, height: info.cellHeight)
            return (leading, leading.offsetBy(dx: CGFloat(info.columns - 1) * (spec.width + spec.gap), dy: 0))
        }
        override func shouldInvalidateLayout(forBoundsChange newBounds: CGRect) -> Bool { newBounds.size != collectionView?.bounds.size }
        override func layoutAttributesForItem(at path: IndexPath) -> UICollectionViewLayoutAttributes? {
            guard sections.indices.contains(path.section), path.item < sections[path.section].count else { return nil }
            let info = sections[path.section], spec = specs[path.section]
            let x: CGFloat, row: Int
            if info.page > 0 {
                let perPage = max(1, info.perPage), index = path.item % perPage
                var column = index % info.columns
                row = index / info.columns
                if info.framed, row == info.rows - 1 { column += 1 }
                x = info.x + CGFloat(path.item / perPage) * info.page + info.inset + CGFloat(column) * (spec.width + spec.gap)
            } else {
                row = path.item % info.rows
                x = info.x + info.inset + CGFloat(path.item / info.rows) * (spec.width + spec.gap)
            }
            let attributes = UICollectionViewLayoutAttributes(forCellWith: path)
            attributes.frame = CGRect(x: x, y: info.top + CGFloat(row) * info.rowStride, width: spec.width, height: info.cellHeight)
            return attributes
        }
        override func layoutAttributesForElements(in rect: CGRect) -> [UICollectionViewLayoutAttributes]? {
            var attributes = [UICollectionViewLayoutAttributes]()
            for (section, info) in sections.enumerated() where info.x + info.width >= rect.minX && info.x <= rect.maxX {
                let stride = stride(section)
                let first = max(0, Int(floor((rect.minX - info.x - info.inset) / stride)))
                let last = max(0, Int(ceil((rect.maxX - info.x) / stride)))
                guard first <= last else { continue }
                let perColumn = info.page > 0 ? max(1, info.perPage) : info.rows
                let lower = first * perColumn, upper = min(info.count, (last + 1) * perColumn)
                guard lower < upper else { continue }
                for item in lower..<upper {
                    if let value = layoutAttributesForItem(at: IndexPath(item: item, section: section)),
                       value.frame.intersects(rect) { attributes.append(value) }
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
