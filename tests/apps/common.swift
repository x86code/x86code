// x86Sim test apps: shared result log. Every check prints "X86TEST <app> <check> PASS|FAIL|SKIP <detail>" to stderr
// (launchd_sim's app log) and appends it to Documents/x86test-results.txt (tests/apps/run.sh reads that file).
// SKIP: the check does not apply here (not supported in Apple's own simulator either); never a failure.
import Foundation

enum X86Test {
    static let app = Bundle.main.bundleIdentifier?.components(separatedBy: ".").last ?? "app"
    static var file: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("x86test-results.txt")
    }
    /// false: stderr / NSLog only (sdkcov --only)
    static var toFile = true
    static func reset() { try? FileManager.default.removeItem(at: file); log("start", true, ProcessInfo.processInfo.operatingSystemVersionString) }
    static func log(_ check: String, _ ok: Bool, _ detail: String = "") { write(check, ok ? "PASS" : "FAIL", detail) }
    static func skip(_ check: String, _ reason: String) { write(check, "SKIP", reason) }
    static func write(_ check: String, _ status: String, _ detail: String) {
        let line = "X86TEST \(app) \(check) \(status) \(detail.replacingOccurrences(of: "\n", with: " "))\n"
        FileHandle.standardError.write(line.data(using: .utf8)!)
        NSLog("%@", line)
        guard toFile else { return }
        if let h = try? FileHandle(forWritingTo: file) { h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); try? h.close() }
        else { try? line.data(using: .utf8)!.write(to: file) }
    }
    static func done() { log("done", true) }
}
