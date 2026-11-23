import Foundation
import os

/// Automatic fallback guard for the default Chinese v2 model (`vimeml-zh-v2-20m`).
///
/// Active only when v2 is selected (default). Falls back to v1 on:
/// 1. Runtime errors (v2 load failure, Core ML error, NaN/non-finite output, empty candidates).
/// 2. Crash loop protection (marker written before loading v2 and cleared on success;
///    2 consecutive unfinished loads switch the default to v1).
/// 3. Latency guard (rolling p95 over the last 50 keys' first-candidate latency > 60 ms).
///
/// Never uses accuracy or user-selection signals. A slow window lasts only for
/// the keyboard process it happened in; a stored fallback expires after
/// `retryInterval`, and resets when the user switches back to v2 or the app
/// version changes, so one bad moment never pins the keyboard to v1.
nonisolated final class ChineseModelFallback: @unchecked Sendable {
    static let shared = ChineseModelFallback()

    static let inFlightKey = "vime.chineseModel.v2LoadInFlight"
    static let crashCountKey = "vime.chineseModel.v2CrashCount"
    static let fallbackActiveKey = "vime.chineseModel.v2AutoFallbackToV1"
    static let fallbackReasonKey = "vime.chineseModel.v2AutoFallbackReason"
    static let appVersionKey = "vime.chineseModel.v2AppVersion"
    static let fallbackDateKey = "vime.chineseModel.v2AutoFallbackDate"
    /// How long a stored fallback holds before v2 is tried again.
    static let retryInterval: TimeInterval = 24 * 60 * 60

    static let crashThreshold = 2
    static let latencyWindowSize = 50
    static let latencyP95LimitMS = 60.0

    private let lock = NSLock()
    private let defaultsProvider: () -> UserDefaults?
    private let appVersionProvider: () -> String
    private let now: () -> Date
    private let log = Logger(subsystem: "com.Voltline.Vime", category: "LanguageModel")
    private var latencySamplesMS: [Double] = []
    private var inMemoryFallbackActive = false
    private var inMemoryFallbackReason: String?

    init(
        defaultsProvider: @escaping () -> UserDefaults? = { UserDefaults(suiteName: KeyboardPreferences.appGroup) },
        appVersionProvider: @escaping () -> String = { ChineseModelFallback.currentBundleVersion() },
        now: @escaping () -> Date = Date.init
    ) {
        self.defaultsProvider = defaultsProvider
        self.appVersionProvider = appVersionProvider
        self.now = now
    }

    static func currentBundleVersion(bundle: Bundle = .main) -> String {
        let short = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
        return "\(short)(\(build))"
    }

    /// Resets auto-fallback state if the app version changed since last recorded.
    private func syncAppVersionLocked(_ defaults: UserDefaults) {
        let current = appVersionProvider()
        let stored = defaults.string(forKey: Self.appVersionKey)
        if stored != current {
            if stored != nil {
                clearFallbackLocked(defaults)
                log.notice("Chinese model fallback state reset for app version \(current, privacy: .public)")
            }
            defaults.set(current, forKey: Self.appVersionKey)
        }
        if defaults.bool(forKey: Self.fallbackActiveKey) {
            let since = defaults.object(forKey: Self.fallbackDateKey) as? Date ?? .distantPast
            if now().timeIntervalSince(since) >= Self.retryInterval {
                clearFallbackLocked(defaults)
                log.notice("Chinese model fallback expired; retrying v2")
            }
        }
    }

    private func clearFallbackLocked(_ defaults: UserDefaults) {
        defaults.removeObject(forKey: Self.inFlightKey)
        defaults.removeObject(forKey: Self.crashCountKey)
        defaults.removeObject(forKey: Self.fallbackActiveKey)
        defaults.removeObject(forKey: Self.fallbackReasonKey)
        defaults.removeObject(forKey: Self.fallbackDateKey)
        inMemoryFallbackActive = false
        inMemoryFallbackReason = nil
        latencySamplesMS.removeAll(keepingCapacity: true)
    }

    /// Whether auto-fallback has switched the effective model to v1.
    var isFallenBackToV1: Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let defaults = defaultsProvider() else { return inMemoryFallbackActive }
        syncAppVersionLocked(defaults)
        return inMemoryFallbackActive || defaults.bool(forKey: Self.fallbackActiveKey)
    }

    /// The recorded reason for the current auto-fallback, if any.
    var fallbackReason: String? {
        lock.lock()
        defer { lock.unlock() }
        guard let defaults = defaultsProvider() else { return inMemoryFallbackActive ? inMemoryFallbackReason : nil }
        syncAppVersionLocked(defaults)
        if defaults.bool(forKey: Self.fallbackActiveKey) { return defaults.string(forKey: Self.fallbackReasonKey) }
        return inMemoryFallbackActive ? inMemoryFallbackReason : nil
    }

    /// Called when the user explicitly selects v2 in settings/preferences.
    func resetForManualV2Selection() {
        lock.lock()
        defer { lock.unlock() }
        inMemoryFallbackActive = false
        inMemoryFallbackReason = nil
        if let defaults = defaultsProvider() {
            clearFallbackLocked(defaults)
            defaults.set(appVersionProvider(), forKey: Self.appVersionKey)
        } else {
            latencySamplesMS.removeAll(keepingCapacity: true)
        }
        log.notice("Chinese model fallback cleared by manual v2 selection")
    }

    /// Called immediately before loading v2.
    /// Returns `true` if v2 loading may proceed, or `false` if a crash loop
    /// (2 consecutive unfinished loads) has triggered fallback to v1.
    func beginV2Load() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let defaults = defaultsProvider() else { return !inMemoryFallbackActive }
        syncAppVersionLocked(defaults)
        if inMemoryFallbackActive || defaults.bool(forKey: Self.fallbackActiveKey) {
            return false
        }
        if defaults.bool(forKey: Self.inFlightKey) {
            let crashes = defaults.integer(forKey: Self.crashCountKey) + 1
            defaults.set(crashes, forKey: Self.crashCountKey)
            if crashes >= Self.crashThreshold {
                activateFallbackLocked(defaults, reason: "crash_loop_\(crashes)")
                return false
            }
            log.error("Detected unfinished Chinese v2 load (crash count \(crashes)/\(Self.crashThreshold))")
        }
        defaults.set(true, forKey: Self.inFlightKey)
        defaults.synchronize()
        return true
    }

    /// Called immediately after v2 finishes loading cleanly.
    func finishV2LoadSuccess() {
        lock.lock()
        defer { lock.unlock() }
        guard let defaults = defaultsProvider() else { return }
        defaults.set(false, forKey: Self.inFlightKey)
        defaults.set(0, forKey: Self.crashCountKey)
    }

    /// Records a v2 runtime failure (load error, Core ML error, NaN, empty output)
    /// and switches the effective model to v1.
    func recordRuntimeFailure(reason: String) {
        lock.lock()
        defer { lock.unlock() }
        inMemoryFallbackActive = true
        inMemoryFallbackReason = reason
        if let defaults = defaultsProvider() {
            syncAppVersionLocked(defaults)
            activateFallbackLocked(defaults, reason: reason)
        } else {
            latencySamplesMS.removeAll(keepingCapacity: true)
            log.error("Chinese v2 runtime failure (\(reason, privacy: .public)); falling back to v1")
        }
    }

    /// Records one keystroke's first-candidate latency (ms) while running on v2.
    /// Returns `true` if the rolling 50-key p95 exceeded 60 ms and triggered fallback to v1.
    @discardableResult
    func recordKeyLatency(milliseconds: Double) -> Bool {
        guard milliseconds.isFinite, milliseconds >= 0 else { return false }
        lock.lock()
        defer { lock.unlock() }
        latencySamplesMS.append(milliseconds)
        if latencySamplesMS.count > Self.latencyWindowSize {
            latencySamplesMS.removeFirst(latencySamplesMS.count - Self.latencyWindowSize)
        }
        guard latencySamplesMS.count == Self.latencyWindowSize else { return false }
        let sorted = latencySamplesMS.sorted()
        let p95Index = min(sorted.count - 1, Int((Double(sorted.count - 1) * 0.95).rounded()))
        let p95 = sorted[p95Index]
        guard p95 > Self.latencyP95LimitMS else { return false }
        let formatted = String(format: "%.1f", p95)
        let reason = "latency_p95_\(formatted)ms"
        // Slowness passes (a cold cache, a hot phone), so it holds only for
        // this keyboard process and is never stored.
        inMemoryFallbackActive = true
        inMemoryFallbackReason = reason
        latencySamplesMS.removeAll(keepingCapacity: true)
        log.error("Chinese v2 rolling p95 latency \(formatted, privacy: .public) ms > 60 ms; falling back to v1")
        return true
    }

    /// Clears only in-memory rolling latency samples (e.g. for tests).
    func resetLatencyWindow() {
        lock.lock()
        defer { lock.unlock() }
        latencySamplesMS.removeAll(keepingCapacity: true)
    }

    private func activateFallbackLocked(_ defaults: UserDefaults, reason: String) {
        defaults.set(false, forKey: Self.inFlightKey)
        defaults.set(true, forKey: Self.fallbackActiveKey)
        defaults.set(reason, forKey: Self.fallbackReasonKey)
        defaults.set(now(), forKey: Self.fallbackDateKey)
        defaults.synchronize()
        latencySamplesMS.removeAll(keepingCapacity: true)
        log.error("Chinese v2 auto-fallback to v1 triggered: \(reason, privacy: .public)")
    }
}
