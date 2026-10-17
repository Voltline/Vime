import UIKit
import CoreText

/// Async preparation is an optimization; a cell entering the viewport must
/// have real pixels even when a fling outruns it or the main queue is busy.
@MainActor
enum KeyboardEmojiImages {
    enum Priority: Int { case prefetch, prepared, anticipated, visible }
    private struct Client {
        var priority: Priority
        let completion: ((UIImage?) -> Void)?
    }
    private struct Job {
        let id = UUID()
        var clients: [UUID: Client] = [:]
        var priority: Priority { clients.values.map(\.priority).max(by: { $0.rawValue < $1.rawValue }) ?? .prefetch }
    }
    private static let cache = EmojiPreparedCache()
    private static let worker = EmojiDecodeWorker(cache: cache)
    private static var jobs: [String: Job] = [:]
    private static var tokens: [UUID: String] = [:]
    private static var generation = 0
    private static var renderColor: CGColor?
    static let byteLimit = EmojiPreparedCache.byteLimit
    static let pendingLimit = 192
    static let prefetchLimit = 96
    static var retainedBytes: Int { cache.retainedBytes }
    static var pendingCount: Int { jobs.count }
    static var cacheGeneration: Int { generation }
    private static func key(_ text: String, _ scale: CGFloat) -> String { "\(scale):\(text)" }

    /// Only outline glyphs depend on text color. UIKit can notify several
    /// appearance traits when a panel attaches; invalidate pixels only when
    /// their actual render color changes. Scale is already part of the key.
    @discardableResult
    static func synchronizeAppearance() -> CGColor {
        let color = KeyboardPalette.text.cgColor
        let previous = renderColor
        renderColor = color
        if let previous, previous != color { clear() }
        return color
    }

    static func cachedImage(_ text: String, scale: CGFloat) -> UIImage? {
        synchronizeAppearance()
        return cache.image(for: key(text, scale))
    }

    /// Only call at the display boundary, never for speculative cells. This
    /// reads worker results before their main-queue callbacks are delivered.
    /// A cold miss paints one small bitmap without waiting behind queued work.
    static func displayImage(_ text: String, scale: CGFloat) -> UIImage? {
        let color = synchronizeAppearance()
        let key = key(text, scale)
        if let image = cache.image(for: key) { return image }
        let timing = KeyboardPerformance.start()
        defer { KeyboardPerformance.record(.emojiVisibleDecode, since: timing) }
        let image = autoreleasepool {
            EmojiRenderer.shared.render(text, scale: scale, color: color)
                .map { UIImage(cgImage: $0, scale: scale, orientation: .up) }
        }
        KeyboardPerformance.record(.emojiDecode, since: timing)
        let ready = image.map { cache.insert($0, key: key, generation: generation) }
        // Resolve coalesced subscriptions now; an obsolete worker result can
        // neither overwrite this image nor call those subscriptions again.
        if let job = jobs.removeValue(forKey: key) {
            worker.cancel(job.id)
            for (token, client) in job.clients {
                tokens.removeValue(forKey: token); client.completion?(ready)
            }
        }
        return ready
    }

    @discardableResult
    static func request(_ text: String, scale: CGFloat, priority: Priority? = nil, completion: ((UIImage?) -> Void)? = nil) -> UUID? {
        let color = synchronizeAppearance()
        if let image = cache.image(for: key(text, scale)) { completion?(image); return nil }
        let priority = priority ?? (completion == nil ? .prefetch : .visible)
        let key = key(text, scale), token = UUID()
        if jobs[key] == nil {
            let speculative = priority == .prefetch || priority == .anticipated
            guard jobs.count < pendingLimit, !speculative
                || jobs.values.filter({ $0.priority == .prefetch || $0.priority == .anticipated }).count < prefetchLimit else { return nil }
            jobs[key] = Job()
        }
        jobs[key]?.clients[token] = Client(priority: priority, completion: completion)
        tokens[token] = key
        guard let job = jobs[key] else { return nil }
        let epoch = generation, id = job.id
        worker.enqueue(id: id, key: key, generation: epoch, text: text, scale: scale,
            color: color, priority: job.priority.rawValue) { image in
            guard epoch == generation, jobs[key]?.id == id, let completed = jobs.removeValue(forKey: key) else { return }
            for (token, client) in completed.clients { tokens.removeValue(forKey: token); client.completion?(image) }
        }
        return token
    }
    static func isPending(_ token: UUID) -> Bool { tokens[token] != nil }
    static func protect(_ texts: [String], scale: CGFloat) {
        let pixels = Int(ceil(36 * max(1, scale)))
        let limit = min(160, byteLimit / (pixels * pixels * 4))
        cache.protect(Set(texts.prefix(limit).map { key($0, scale) }))
    }
    static func promote(_ token: UUID?, to priority: Priority) {
        guard let token, let key = tokens[token], jobs[key]?.clients[token] != nil else { return }
        jobs[key]?.clients[token]?.priority = priority
        if let job = jobs[key] { worker.setPriority(job.id, priority: job.priority.rawValue) }
    }
    static func cancel(_ token: UUID?) {
        guard let token, let key = tokens.removeValue(forKey: token), var job = jobs[key] else { return }
        job.clients.removeValue(forKey: token)
        if job.clients.isEmpty { jobs.removeValue(forKey: key); worker.cancel(job.id) }
        else { jobs[key] = job; worker.setPriority(job.id, priority: job.priority.rawValue) }
    }
    static func image(_ text: String, scale: CGFloat) async -> UIImage? {
        if let image = cachedImage(text, scale: scale) { return image }
        guard jobs[key(text, scale)] != nil || jobs.count < pendingLimit else { return nil }
        return await withCheckedContinuation { continuation in
            request(text, scale: scale) { continuation.resume(returning: $0) }
        }
    }
    static func clear() {
        generation += 1
        // Invalidate under the same lock used for insertion, before cancelling
        // callbacks. An in-flight decode cannot repopulate the cleared cache.
        cache.clear(generation: generation)
        let callbacks = jobs.values.flatMap { $0.clients.values.compactMap(\.completion) }
        jobs.removeAll(); tokens.removeAll(); worker.clear()
        for callback in callbacks { callback(nil) }
    }
}

/// Both the serial worker and the display boundary can use this cache. Never
/// hold its lock while shaping, decoding, preparing images or calling clients.
nonisolated private final class EmojiPreparedCache: @unchecked Sendable {
    static let byteLimit = 8 * 1_048_576
    private let lock = NSLock()
    private var images: [String: UIImage] = [:]
    private var order: [String] = []
    private var protected = Set<String>()
    private var bytes = 0
    private var generation = 0
    var retainedBytes: Int { lock.lock(); defer { lock.unlock() }; return bytes }
    func image(for key: String) -> UIImage? {
        lock.lock(); defer { lock.unlock() }
        guard let image = images[key] else { return nil }
        order.removeAll { $0 == key }; order.append(key)
        return image
    }
    func protect(_ keys: Set<String>) {
        lock.lock(); protected = keys; lock.unlock()
    }
    @discardableResult
    func insert(_ image: UIImage, key: String, generation epoch: Int) -> UIImage {
        lock.lock(); defer { lock.unlock() }
        guard epoch == generation else { return image }
        if let existing = images[key] { return existing }
        guard let cg = image.cgImage else { return image }
        let cost = cg.bytesPerRow * cg.height
        while !order.isEmpty && (bytes + cost > Self.byteLimit || order.count >= 240) {
            guard let index = order.firstIndex(where: { !protected.contains($0) }) else { return image }
            let oldest = order.remove(at: index)
            if let removed = images.removeValue(forKey: oldest)?.cgImage { bytes -= removed.bytesPerRow * removed.height }
        }
        if cost <= Self.byteLimit { images[key] = image; order.append(key); bytes += cost }
        return image
    }
    func clear(generation epoch: Int) {
        lock.lock(); defer { lock.unlock() }
        generation = epoch; images.removeAll(); order.removeAll(); protected.removeAll(); bytes = 0
    }
}

/// Queue metadata is protected by the lock. At most 24 completed images await
/// main-thread delivery. Prepared pixels become readable BEFORE that delivery.
nonisolated private final class EmojiDecodeWorker: @unchecked Sendable {
    private struct Work: @unchecked Sendable {
        let id: UUID
        let key: String
        let generation: Int
        let text: String
        let scale: CGFloat
        let color: CGColor
        var priority: Int
        let complete: @MainActor @Sendable (UIImage?) -> Void
    }
    private let cache: EmojiPreparedCache
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "com.Voltline.Vime.emojiDecode", qos: .userInitiated)
    private var work: [UUID: Work] = [:]
    private var order: [UUID] = []
    private var inFlight = Set<UUID>()
    private var running = false
    private var deliveries = 0
    init(cache: EmojiPreparedCache) { self.cache = cache }
    func enqueue(id: UUID, key: String, generation: Int, text: String, scale: CGFloat, color: CGColor, priority: Int,
        complete: @escaping @MainActor @Sendable (UIImage?) -> Void) {
        lock.lock(); defer { lock.unlock() }
        if inFlight.contains(id) { return }
        if work[id] != nil { work[id]?.priority = priority; return }
        work[id] = Work(id: id, key: key, generation: generation, text: text, scale: scale, color: color, priority: priority, complete: complete)
        order.append(id); scheduleLocked()
    }
    func setPriority(_ id: UUID, priority: Int) {
        lock.lock(); work[id]?.priority = priority; lock.unlock()
    }
    func cancel(_ id: UUID) {
        lock.lock(); work.removeValue(forKey: id); order.removeAll { $0 == id }; lock.unlock()
    }
    func clear() {
        lock.lock(); work.removeAll(); order.removeAll(); lock.unlock()
    }
    private func scheduleLocked() {
        guard !running, deliveries < 24, !order.isEmpty else { return }
        running = true; queue.async { self.drain() }
    }
    private func next() -> Work? {
        lock.lock(); defer { lock.unlock() }
        guard deliveries < 24, !order.isEmpty else { running = false; return nil }
        var best = 0
        for index in order.indices where (work[order[index]]?.priority ?? -1) > (work[order[best]]?.priority ?? -1) { best = index }
        let id = order.remove(at: best)
        guard let item = work.removeValue(forKey: id) else { running = false; return nil }
        inFlight.insert(id); deliveries += 1
        return item
    }
    private func drain() {
        while let item = next() {
            let image = autoreleasepool { () -> UIImage? in
                if let cached = cache.image(for: item.key) { return cached }
                let timing = KeyboardPerformance.start()
                let bitmap = EmojiRenderer.shared.render(item.text, scale: item.scale, color: item.color)
                KeyboardPerformance.record(.emojiDecode, since: timing)
                return bitmap.map { cache.insert(UIImage(cgImage: $0, scale: item.scale, orientation: .up),
                    key: item.key, generation: item.generation) }
            }
            DispatchQueue.main.async {
                item.complete(image)
                self.lock.lock(); self.inFlight.remove(item.id); self.deliveries -= 1; self.scheduleLocked(); self.lock.unlock()
            }
        }
    }
}

/// Immutable font/table references can be shared across threads (CoreText).
/// Every render owns its shape objects and CGContext; no native glyph painting.
nonisolated private final class EmojiRenderer: @unchecked Sendable {
    static let shared = EmojiRenderer()
    private let font: CTFont
    private let bitmaps: EmojiBitmapFont?
    private init() {
        let font = CTFontCreateWithName("AppleColorEmoji" as CFString, 29, nil)
        self.font = font; bitmaps = EmojiBitmapFont(font: font)
    }
    func render(_ text: String, scale: CGFloat, color: CGColor) -> CGImage? {
        guard let bitmaps else { return nil }
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text,
            attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font]))
        var parts = [(image: CGImage, rect: CGRect, flipped: Bool)]()
        var outlines = [CGPath]()
        var bounds = CGRect.null
        let strike = bitmaps.strike(for: 29 * scale)
        for run in CTLineGetGlyphRuns(line) as! [CTRun] {
            let runFont = (CTRunGetAttributes(run) as NSDictionary)[kCTFontAttributeName] as! CTFont
            let count = CTRunGetGlyphCount(run)
            if !(CTFontCopyPostScriptName(runFont) as String).contains("AppleColorEmoji") {
                if CTRunGetTypographicBounds(run, CFRange(location: 0, length: 0), nil, nil, nil) == 0 { continue }
                return nil
            }
            var glyphs = [CGGlyph](repeating: 0, count: count)
            var positions = [CGPoint](repeating: .zero, count: count)
            CTRunGetGlyphs(run, CFRange(location: 0, length: 0), &glyphs)
            CTRunGetPositions(run, CFRange(location: 0, length: 0), &positions)
            for (index, glyph) in glyphs.enumerated() {
                guard let bitmap = bitmaps.bitmap(glyph: Int(glyph), strike: strike) else {
                    // Gender/medical signs in the system font are true
                    // outlines, without a bitmap at any resolution.
                    if !bitmaps.hasBitmap(glyph: Int(glyph)), let path = CTFontCreatePathForGlyph(runFont, glyph, nil), !path.isEmpty {
                        let factor = strike.ppem / CTFontGetSize(runFont)
                        var transform = CGAffineTransform(a: factor, b: 0, c: 0, d: factor,
                            tx: positions[index].x * factor, ty: positions[index].y * factor)
                        if let path = path.copy(using: &transform) {
                            outlines.append(path); bounds = bounds.union(path.boundingBoxOfPath); continue
                        }
                    }
                    if CTRunGetTypographicBounds(run, CFRange(location: index, length: 1), nil, nil, nil) == 0 { continue }
                    return nil
                }
                let resolution = strike.ppem / bitmap.ppem
                let rect = CGRect(x: bitmap.origin.x * resolution + positions[index].x * strike.ppem / CTFontGetSize(runFont),
                    y: bitmap.origin.y * resolution + positions[index].y * strike.ppem / CTFontGetSize(runFont),
                    width: CGFloat(bitmap.image.width) * resolution, height: CGFloat(bitmap.image.height) * resolution)
                bounds = bounds.union(rect)
                parts.append((bitmap.image, rect, bitmap.flipped))
            }
        }
        guard (!parts.isEmpty || !outlines.isEmpty), !bounds.isEmpty else { return nil }
        let pixels = Int(ceil(36 * scale))
        guard let context = CGContext(data: nil, width: pixels, height: pixels,
            bitsPerComponent: 8, bytesPerRow: pixels * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else { return nil }
        context.scaleBy(x: scale, y: scale)
        let factor = min(29 / strike.ppem, min(34 / bounds.width, 34 / bounds.height))
        context.translateBy(x: 18, y: 18); context.scaleBy(x: factor, y: factor)
        context.translateBy(x: -bounds.midX, y: -bounds.midY)
        for part in parts {
            context.saveGState()
            if part.flipped {
                context.translateBy(x: part.rect.minX + part.rect.maxX, y: 0); context.scaleBy(x: -1, y: 1)
            }
            context.draw(part.image, in: part.rect)
            context.restoreGState()
        }
        context.setFillColor(color)
        for path in outlines { context.addPath(path); context.fillPath() }
        // CGContext already owns eager, premultiplied BGRA pixels. Passing
        // those through UIImage preparation again can create another backing
        // store. The image view can consume this uncompressed bitmap directly.
        return context.makeImage()
    }
}
