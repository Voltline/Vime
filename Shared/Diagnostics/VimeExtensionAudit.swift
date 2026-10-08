import Foundation
import Darwin

#if DEBUG || VIME_EXTENSION_AUDIT
/// Bounded opt-in measurement in the real keyboard extension. Enabled only by
/// an explicit App Group sentinel installed by the developer; records no text.
nonisolated final class VimeExtensionAudit: @unchecked Sendable {
    private static let active: VimeExtensionAudit? = {
        guard Bundle.main.bundleURL.pathExtension == "appex",
              let group = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: KeyboardPreferences.appGroup),
              let data = try? Data(contentsOf: group.appendingPathComponent("v21-audit-enabled.json")),
              let flag = try? JSONSerialization.jsonObject(with: data) as? [String: Bool],
              flag["enabled"] == true else { return nil }
        return VimeExtensionAudit(group: group)
    }()
    static func start() { _ = active }
    /// Explicit developer launch arguments control the shared sentinel from the
    /// actual app process (XCTest may use an isolated App Group container).
    static func configureFromLaunchArguments() {
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("--v21-extension-audit-export"),
           let group = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: KeyboardPreferences.appGroup),
           let files = try? FileManager.default.contentsOfDirectory(at: group, includingPropertiesForKeys: nil) {
            for file in files where file.lastPathComponent.hasPrefix("v21-extension-audit-") && file.pathExtension == "json" {
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
            let data = try JSONSerialization.data(withJSONObject: ["enabled": enabled])
            try data.write(to: group.appendingPathComponent("v21-audit-enabled.json"), options: .atomic)
            print("VIME_EXTENSION_AUDIT_CONTROL enabled=\(enabled) group=\(group.path)")
        } catch {
            print("VIME_EXTENSION_AUDIT_CONTROL error=\(error)")
        }
    }
    static func recordModelLoad(version: String, milliseconds: Int) {
        guard let audit = active else { return }
        audit.lock.lock()
        audit.loads.append(["model_version": version, "load_ms": milliseconds,
                            "seconds": ProcessInfo.processInfo.systemUptime - audit.started])
        audit.lock.unlock()
    }
    private let lock = NSLock()
    private let timer: DispatchSourceTimer
    private let output: URL
    private let started = ProcessInfo.processInfo.systemUptime
    private let startedUTC = ISO8601DateFormatter().string(from: Date())
    private var samples = [[String: Double]]()
    private var loads = [[String: Any]]()
    private init(group: URL) {
        output = group.appendingPathComponent("v21-extension-audit-\(getpid()).json")
        timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "com.Voltline.Vime.extensionAudit"))
        KeyboardPerformance.configure(enabled: true, reset: true)
        timer.schedule(deadline: .now(), repeating: .milliseconds(100))
        timer.setEventHandler { [weak self] in self?.sample() }
        timer.resume()
    }
    private func sample() {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let capacity = Int(count)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: capacity) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return }
        let seconds = ProcessInfo.processInfo.systemUptime - started
        lock.lock()
        samples.append(["seconds": seconds, "physical_mib": Double(info.phys_footprint) / 1_048_576,
                        "resident_mib": Double(info.resident_size) / 1_048_576,
                        "process_lifetime_peak_mib": Double(info.ledger_phys_footprint_peak) / 1_048_576])
        let shouldWrite = samples.count % 20 == 0 || seconds >= 240
        let values = samples
        let modelLoads = loads
        lock.unlock()
        if shouldWrite {
            let preferences = KeyboardPreferences()
            let report: [String: Any] = ["format": "vime_extension_audit_v21", "scope": "physical keyboard extension",
                "pid": getpid(), "started_utc": startedUTC, "elapsed_seconds": seconds,
                "bundle_id": Bundle.main.bundleIdentifier ?? "unknown", "os": ProcessInfo.processInfo.operatingSystemVersionString,
                "settings": ["candidate_ranking": preferences.candidateRanking.rawValue,
                             "next_words": preferences.phraseSuggestions], "model_loads": modelLoads,
                "samples": values, "timing": KeyboardPerformance.report(),
                "note": "100ms in-process footprint/resident samples and lifetime peak; instrumentation adds overhead. Timing includes attempts/cancellation. No text recorded. Auto-stops at 240s."]
            if let data = try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]) {
                try? data.write(to: output, options: .atomic)
            }
        }
        if seconds >= 240 {
            timer.cancel()
            KeyboardPerformance.configure(enabled: false)
        }
    }
}

#else
/// Distribution builds cannot enable auditing through a leftover sentinel.
nonisolated enum VimeExtensionAudit {
    static func start() {}
    static func configureFromLaunchArguments() {}
    static func recordModelLoad(version: String, milliseconds: Int) {}
}
#endif
