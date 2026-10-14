import Foundation
import Darwin
import os

#if DEBUG || VIME_EXTENSION_AUDIT
/// Bounded opt-in measurement in the actual keyboard extension. Enabled only
/// by an explicit App Group sentinel; records timings and resources, never text.
nonisolated final class VimeExtensionAudit: @unchecked Sendable {
    struct Configuration: Equatable, Sendable {
        let durationSeconds: Int
        let sampleMilliseconds: Int
        let writeMilliseconds: Int
        let runID: String?

        /// Preserve the short diagnostic's defaults. Long sampling must be
        /// requested explicitly, and all sentinel values are bounded again in
        /// the extension rather than trusting the main app's serialization.
        init(durationSeconds: Int = 240, sampleMilliseconds: Int = 100,
             writeMilliseconds: Int = 2_000, runID: String? = nil) {
            self.durationSeconds = min(3_600, max(10, durationSeconds))
            self.sampleMilliseconds = min(10_000, max(100, sampleMilliseconds))
            self.writeMilliseconds = min(60_000, max(self.sampleMilliseconds, max(1_000, writeMilliseconds)))
            if let runID, !runID.isEmpty, runID.utf8.count <= 64,
               runID.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0)
                   || (97...122).contains($0) || $0 == 45 || $0 == 95 }) {
                self.runID = runID
            } else {
                self.runID = nil
            }
        }

        init(sentinel: [String: Any]) {
            self.init(durationSeconds: sentinel["duration_seconds"] as? Int ?? 240,
                      sampleMilliseconds: sentinel["sample_ms"] as? Int ?? 100,
                      writeMilliseconds: sentinel["write_ms"] as? Int ?? 2_000,
                      runID: sentinel["run_id"] as? String)
        }

        static func from(arguments: [String]) -> Configuration {
            func value(_ key: String) -> String? {
                if let argument = arguments.first(where: { $0.hasPrefix(key + "=") }) {
                    return String(argument.dropFirst(key.count + 1))
                }
                guard let index = arguments.firstIndex(of: key), index + 1 < arguments.count else { return nil }
                return arguments[index + 1]
            }
            return Configuration(
                durationSeconds: value("--v21-extension-audit-duration-seconds").flatMap(Int.init) ?? 240,
                sampleMilliseconds: value("--v21-extension-audit-sample-ms").flatMap(Int.init) ?? 100,
                writeMilliseconds: value("--v21-extension-audit-write-ms").flatMap(Int.init) ?? 2_000,
                runID: value("--v21-extension-audit-run-id"))
        }

        var dictionary: [String: Any] {
            var result: [String: Any] = ["duration_seconds": durationSeconds,
                "sample_ms": sampleMilliseconds, "write_ms": writeMilliseconds]
            if let runID { result["run_id"] = runID }
            return result
        }
    }

    /// Closed set prevents accidental input text from entering diagnostics.
    enum LifecycleEvent: String, Sendable {
        case viewDidLoad = "view_did_load"
        case viewWillAppear = "view_will_appear"
        case viewDidAppear = "view_did_appear"
        case viewWillDisappear = "view_will_disappear"
        case viewDidDisappear = "view_did_disappear"
        case memoryWarning = "memory_warning"
        case auditStarted = "audit_started"
        case auditStopped = "audit_stopped"
    }

    private static let active: VimeExtensionAudit? = {
        guard Bundle.main.bundleURL.pathExtension == "appex",
              let group = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: KeyboardPreferences.appGroup),
              let data = try? Data(contentsOf: group.appendingPathComponent("v21-audit-enabled.json")),
              let flag = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              flag["enabled"] as? Bool == true else { return nil }
        return VimeExtensionAudit(group: group, configuration: Configuration(sentinel: flag))
    }()

    static func start() { _ = active }

    /// The main app owns configuration because XCTest may have an isolated App
    /// Group container. Export does not require enabling sampling.
    static func configureFromLaunchArguments() {
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("--v21-extension-audit-export"),
           let group = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: KeyboardPreferences.appGroup),
           let files = try? FileManager.default.contentsOfDirectory(at: group, includingPropertiesForKeys: nil) {
            for file in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
                where file.lastPathComponent.hasPrefix("v21-extension-audit-") && file.pathExtension == "json" {
                if let data = try? Data(contentsOf: file), let text = String(data: data, encoding: .utf8) {
                    print("VIME_EXTENSION_AUDIT_REPORT \(text)")
                }
            }
        }
        let enabled: Bool
        if arguments.contains("--v21-extension-audit-on") { enabled = true }
        else if arguments.contains("--v21-extension-audit-off") { enabled = false }
        else { return }
        guard let group = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: KeyboardPreferences.appGroup) else {
            print("VIME_EXTENSION_AUDIT_CONTROL missing App Group"); return
        }
        do {
            var sentinel = Configuration.from(arguments: arguments).dictionary
            sentinel["enabled"] = enabled
            let data = try JSONSerialization.data(withJSONObject: sentinel)
            try data.write(to: group.appendingPathComponent("v21-audit-enabled.json"), options: .atomic)
            print("VIME_EXTENSION_AUDIT_CONTROL enabled=\(enabled) group=\(group.path)")
        } catch {
            print("VIME_EXTENSION_AUDIT_CONTROL error=\(error)")
        }
    }

    static func recordModelLoad(version: String, milliseconds: Int) {
        guard let audit = active else { return }
        audit.lock.lock(); defer { audit.lock.unlock() }
        guard !audit.stopped else { return }
        if audit.loads.count == Self.maximumModelLoads {
            audit.loads.removeFirst(); audit.droppedModelLoads += 1
        }
        audit.loads.append(["model_version": String(version.prefix(64)), "load_ms": milliseconds,
                            "seconds": ProcessInfo.processInfo.systemUptime - audit.started])
    }

    static func recordLifecycle(event: LifecycleEvent) {
        active?.record(event)
    }

    private static let maximumSamples = 4_096
    private static let maximumTimingWindows = 256
    private static let maximumModelLoads = 32
    private static let maximumLifecycleEvents = 128
    private static let log = Logger(subsystem: "com.Voltline.Vime", category: "ExtensionAudit")
    private let lock = NSLock()
    private let timer: DispatchSourceTimer
    private let configuration: Configuration
    private var output: URL
    private var outputStorage = "app_group"
    private var writeFailures = 0
    private var loggedOutput = false
    private let started = ProcessInfo.processInfo.systemUptime
    private let startedUTC = ISO8601DateFormatter().string(from: Date())
    private let initialCPU = VimeExtensionAudit.processCPU()
    private var samples = [[String: Double]]()
    private var loads = [[String: Any]]()
    private var events = [[String: Any]]()
    private var lifecycleCounts: [LifecycleEvent: Int] = [:]
    private var timingWindows = [[String: Any]]()
    private var lastWriteSeconds = 0.0
    private var droppedSamples = 0
    private var droppedModelLoads = 0
    private var droppedLifecycleEvents = 0
    private var droppedTimingWindows = 0
    private var failedMemorySamples = 0
    private var stopped = false

    private init(group: URL, configuration: Configuration) {
        self.configuration = configuration
        let suffix = configuration.runID.map { "\($0)-\(getpid())" } ?? "\(getpid())"
        output = group.appendingPathComponent("v21-extension-audit-\(suffix).json")
        timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "com.Voltline.Vime.extensionAudit", qos: .utility))
        KeyboardPerformance.configure(enabled: true, reset: true)
        record(.auditStarted)
        timer.schedule(deadline: .now(), repeating: .milliseconds(configuration.sampleMilliseconds),
                       leeway: .milliseconds(min(100, configuration.sampleMilliseconds / 10)))
        timer.setEventHandler { [weak self] in self?.sample() }
        timer.resume()
    }

    private func record(_ event: LifecycleEvent) {
        lock.lock(); defer { lock.unlock() }
        guard !stopped else { return }
        lifecycleCounts[event, default: 0] += 1
        if events.count == Self.maximumLifecycleEvents {
            events.removeFirst(); droppedLifecycleEvents += 1
        }
        events.append(["event": event.rawValue, "seconds": ProcessInfo.processInfo.systemUptime - started])
    }

    /// getrusage(RUSAGE_SELF) includes all process threads, unlike live-thread
    /// task_thread_times_info which can omit work done by threads that exited.
    private static func processCPU() -> (user: Double, system: Double)? {
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else { return nil }
        return (Double(usage.ru_utime.tv_sec) + Double(usage.ru_utime.tv_usec) / 1_000_000,
                Double(usage.ru_stime.tv_sec) + Double(usage.ru_stime.tv_usec) / 1_000_000)
    }

    private func sample() {
        autoreleasepool {
            sampleAndWriteIfNeeded()
        }
    }

    private func sampleAndWriteIfNeeded() {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let capacity = Int(count)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: capacity) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        let seconds = ProcessInfo.processInfo.systemUptime - started
        let ended = seconds >= Double(configuration.durationSeconds)
        var value = ["seconds": seconds]
        if result == KERN_SUCCESS {
            value["physical_mib"] = Double(info.phys_footprint) / 1_048_576
            value["resident_mib"] = Double(info.resident_size) / 1_048_576
            value["process_lifetime_peak_mib"] = Double(info.ledger_phys_footprint_peak) / 1_048_576
            value["available_memory_mib"] = Double(os_proc_available_memory()) / 1_048_576
            value["compressed_mib"] = Double(info.compressed) / 1_048_576
            value["internal_mib"] = Double(info.internal) / 1_048_576
            value["external_mib"] = Double(info.external) / 1_048_576
        }
        if let cpu = Self.processCPU() {
            value["cpu_user_seconds"] = cpu.user
            value["cpu_system_seconds"] = cpu.system
            if let initialCPU {
                value["cpu_user_since_start_seconds"] = cpu.user - initialCPU.user
                value["cpu_system_since_start_seconds"] = cpu.system - initialCPU.system
            }
        }
        lock.lock()
        if result != KERN_SUCCESS { failedMemorySamples += 1 }
        if samples.count == Self.maximumSamples { samples.removeFirst(); droppedSamples += 1 }
        samples.append(value)
        lock.unlock()

        // Do not take COW snapshots of the growing arrays at each sample. Only
        // copy at the write cadence, off the input thread, then release them.
        guard ended || seconds - lastWriteSeconds >= Double(configuration.writeMilliseconds) / 1_000 else { return }
        let timing = KeyboardPerformance.takeWindowReport()
        let window: [String: Any] = ["from_seconds": lastWriteSeconds, "to_seconds": seconds, "stages": timing]
        lastWriteSeconds = seconds
        if ended { record(.auditStopped) }
        lock.lock()
        if timingWindows.count == Self.maximumTimingWindows {
            timingWindows.removeFirst(); droppedTimingWindows += 1
        }
        timingWindows.append(window)
        if ended { stopped = true }
        let values = samples
        let modelLoads = loads
        let lifecycleEvents = events
        let eventCounts = Dictionary(uniqueKeysWithValues: lifecycleCounts.map { ($0.key.rawValue, $0.value) })
        let windows = timingWindows
        let discarded: [String: Int] = ["samples": droppedSamples, "model_loads": droppedModelLoads,
            "lifecycle_events": droppedLifecycleEvents, "timing_windows": droppedTimingWindows,
            "failed_memory_samples": failedMemorySamples]
        lock.unlock()

        #if targetEnvironment(simulator)
        let environment = "simulator"
        let scope = "simulator keyboard extension"
        #else
        let environment = "physical_device"
        let scope = "physical keyboard extension"
        #endif
        let preferences = KeyboardPreferences()
        var report: [String: Any] = ["format": "vime_extension_audit_v21", "schema_version": 2,
            "scope": scope, "environment": environment, "pid": getpid(), "started_utc": startedUTC,
            "elapsed_seconds": seconds, "ended": ended,
            "bundle_id": Bundle.main.bundleIdentifier ?? "unknown", "os": ProcessInfo.processInfo.operatingSystemVersionString,
            "configuration": configuration.dictionary,
            "settings": ["candidate_ranking": preferences.candidateRanking.rawValue,
                         "next_words": preferences.phraseSuggestions],
            "model_loads": modelLoads, "lifecycle_events": lifecycleEvents,
            "samples": values, "timing": KeyboardPerformance.report(), "timing_windows": windows,
            "lifecycle_counts": eventCounts,
            "discarded": discarded,
            "note": "In-process resource samples include instrumentation overhead. CPU is cumulative getrusage(RUSAGE_SELF). Timing includes attempts/cancellations. Rolling timing retains 256 calls per stage; totalCount is cumulative. Windows cover all calls for count/mean/max; p95TailMs covers at most the last 256 calls per window. No input text recorded. Simulator results do not establish device memory or energy behavior."]
        if let runID = configuration.runID { report["run_id"] = runID }
        persist(report)
        if ended {
            timer.cancel()
            KeyboardPerformance.configure(enabled: false)
        }
    }

    /// Without Full Access, the shared container may be read-only. Keep reading
    /// its opt-in sentinel, but put diagnostics in the extension's own container
    /// if the first shared write fails. Never change keyboard access settings.
    private func persist(_ initialReport: [String: Any]) {
        var report = initialReport
        report["output_storage"] = outputStorage
        report["write_failures"] = writeFailures
        do {
            let data = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
            try data.write(to: output, options: .atomic)
            logOutputIfNeeded()
        } catch {
            writeFailures += 1
            Self.log.error("audit write failed path=\(self.output.path, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
            guard outputStorage == "app_group",
                  let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return }
            let directory = support.appendingPathComponent("VimeDiagnostics", isDirectory: true)
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                output = directory.appendingPathComponent(output.lastPathComponent)
                outputStorage = "extension_application_support"
                report["output_storage"] = outputStorage
                report["write_failures"] = writeFailures
                let data = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
                try data.write(to: output, options: .atomic)
                logOutputIfNeeded()
            } catch {
                writeFailures += 1
                Self.log.error("audit fallback write failed directory=\(directory.path, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func logOutputIfNeeded() {
        guard !loggedOutput else { return }
        loggedOutput = true
        Self.log.notice("audit output storage=\(self.outputStorage, privacy: .public) path=\(self.output.path, privacy: .public)")
    }
}

#else
/// Distribution builds cannot enable auditing through a leftover sentinel.
nonisolated enum VimeExtensionAudit {
    enum LifecycleEvent: String, Sendable {
        case viewDidLoad, viewWillAppear, viewDidAppear, viewWillDisappear, viewDidDisappear
        case memoryWarning, auditStarted, auditStopped
    }
    static func start() {}
    static func configureFromLaunchArguments() {}
    static func recordModelLoad(version: String, milliseconds: Int) {}
    static func recordLifecycle(event: LifecycleEvent) {}
}
#endif
