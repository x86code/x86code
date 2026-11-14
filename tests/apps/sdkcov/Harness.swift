// sdkcov harness: runs every check once, in order, logging "X86TEST sdkcov <id> PASS|FAIL|SKIP <detail>"
// (common.swift). A crash or hang must not end the run: before each check its id goes to Documents/sdkcov-progress;
// a relaunch (sdkcov/run.sh relaunches until "done") finds the results file without "done", resumes after the last
// finished check and reports the one in the progress file as FAIL "process died". A check that blocks past its
// hard limit (watchdog) is reported FAIL "hung" and the process exits, so the next launch moves on.
import Foundation
import SwiftUI

struct Skip: Error { let reason: String; init(_ r: String) { reason = r } }
struct Fail: Error, CustomStringConvertible { let description: String; init(_ d: String) { description = d } }
/// throw Fail(msg) unless c
func expect(_ c: Bool, _ msg: @autoclosure () -> String) throws { if !c { throw Fail(msg()) } }
/// throw Skip(reason) when c: the check needs something Apple's simulator does not have either
func skipIf(_ c: Bool, _ reason: @autoclosure () -> String) throws { if c { throw Skip(reason()) } }
func onMain<T>(_ f: @MainActor () throws -> T) async rethrows -> T { try await MainActor.run(body: f) }

/// a functional check: it covers framework `fw` (the manifest's name); id "func:<fw>.<name>"
struct Check {
    let fw: String, name: String, timeout: Double
    let run: () async throws -> String
    var id: String { "func:\(fw).\(name)" }
}
func check(_ fw: String, _ name: String, timeout: Double = 30, _ body: @escaping () async throws -> String) -> Check {
    Check(fw: fw, name: name, timeout: timeout, run: body)
}

struct ManifestItem: Decodable {
    let kind: String, name: String, status: String
    let path: String?, reason: String?
    let probes: [[String: String]]?
}
struct Manifest: Decodable { let platform: String, sdk: String, runtime: String, items: [ManifestItem] }

final class Runner: ObservableObject {
    static let shared = Runner()
    @Published var phase = "starting"
    @Published var current = ""
    @Published var pass = 0
    @Published var fail = 0
    @Published var skip = 0
    @Published var total = 0
    @Published var failures: [String] = []
    @Published var finished = false
    var manifest: Manifest?

    let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    var progressFile: URL { docs.appendingPathComponent("sdkcov-progress") }
    var completed = Set<String>()
    var statuses: [String: (String, String)] = [:]   // id -> (status, detail), for the coverage report
    private var running: (id: String, since: Date, limit: Double)?
    private let lock = NSLock()

    func start() {
        Thread.detachNewThread { self.watchdog() }
        Task.detached(priority: .userInitiated) { await self.main() }
    }

    // MARK: resume
    private func prepare() {
        let prev = (try? String(contentsOf: X86Test.file, encoding: .utf8)) ?? ""
        let lines = prev.split(separator: "\n").map(String.init)
        if lines.isEmpty || lines.contains(where: { $0.hasPrefix("X86TEST \(X86Test.app) done ") }) {
            try? FileManager.default.removeItem(at: progressFile)
            X86Test.reset()
            return
        }
        for l in lines {
            let f = l.split(separator: " ", maxSplits: 4).map(String.init)
            guard f.count >= 4 else { continue }
            completed.insert(f[2]); statuses[f[2]] = (f[3], f.count > 4 ? f[4] : "")
            switch f[3] { case "PASS": pass += 1; case "FAIL": fail += 1; failures.append("\(f[2]) \(f.count > 4 ? f[4] : "")"); case "SKIP": skip += 1; default: break }
        }
        X86Test.write("resume", "PASS", "after \(completed.count) results")
        if let id = try? String(contentsOf: progressFile, encoding: .utf8), !id.isEmpty, !completed.contains(id) {
            record(id, "FAIL", "process died during this check (crash, or the hang watchdog)")
        }
    }

    private func record(_ id: String, _ status: String, _ detail: String) {
        X86Test.write(id, status, detail)
        lock.withLock { completed.insert(id); statuses[id] = (status, detail) }
        DispatchQueue.main.async {
            switch status {
            case "PASS": self.pass += 1
            case "FAIL": self.fail += 1; self.failures.append("\(id) \(detail)")
            default: self.skip += 1
            }
        }
    }

    // MARK: watchdog: a check blocked well past its limit (dlopen deadlock, a sync XPC wait) ends the process
    private func watchdog() {
        while true {
            Thread.sleep(forTimeInterval: 2)
            let r = lock.withLock { running }
            guard let r, Date().timeIntervalSince(r.since) > r.limit * 2 + 30 else { continue }
            record(r.id, "FAIL", "hung: no answer in \(Int(Date().timeIntervalSince(r.since))) s")
            try? FileManager.default.removeItem(at: progressFile)
            exit(75)   // sdkcov/run.sh relaunches; the resume continues after this check
        }
    }

    /// run one check once (skipped when a previous launch finished it), with a soft timeout
    func run(_ id: String, timeout: Double, _ body: @escaping () async throws -> String) async {
        if completed.contains(id) { return }
        if let only, !only.contains(where: { id.contains($0) }) { return }
        if only == nil { try? id.write(to: progressFile, atomically: true, encoding: .utf8) }
        lock.withLock { running = (id, Date(), timeout) }
        await MainActor.run { self.current = id }
        let t0 = Date()
        let result: (String, String) = await withTaskGroup(of: (String, String)?.self) { g in
            g.addTask {
                do { return ("PASS", try await body()) }
                catch let s as Skip { return ("SKIP", s.reason) }
                catch { return ("FAIL", "\(error)") }
            }
            g.addTask {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1e9))
                return Task.isCancelled ? nil : ("FAIL", "timed out after \(Int(timeout)) s")
            }
            for await r in g { if let r { g.cancelAll(); return r } }
            return ("FAIL", "no result")
        }
        lock.withLock { running = nil }
        let ms = Int(Date().timeIntervalSince(t0) * 1000)
        record(id, result.0, result.1.isEmpty ? "\(ms) ms" : "\(result.1) (\(ms) ms)")
        if only == nil { try? FileManager.default.removeItem(at: progressFile) }
    }

    /// --only a,b: run only checks whose id contains a or b, reporting on stderr only (the results file is untouched)
    let only: [String]? = {
        let a = ProcessInfo.processInfo.arguments
        guard let i = a.firstIndex(of: "--only"), i + 1 < a.count else { return nil }
        return a[i + 1].split(separator: ",").map(String.init)
    }()

    // MARK: main
    func main() async {
        if let only {
            X86Test.toFile = false
            X86Test.write("only", "PASS", only.joined(separator: ","))
        } else {
            prepare()
        }
        guard let u = Bundle.main.url(forResource: "manifest", withExtension: "json"),
              let d = try? Data(contentsOf: u), let m = try? JSONDecoder().decode(Manifest.self, from: d) else {
            X86Test.log("manifest", false, "manifest.json missing from the bundle"); X86Test.done(); return
        }
        manifest = m
        let checks = Registry.all
        await MainActor.run { self.total = m.items.count + checks.count + 1 }
        // 1. every framework / library of the SDK: load it and resolve its representative exports
        await MainActor.run { self.phase = "loading \(m.items.count) frameworks and libraries" }
        for it in m.items {
            let id = "load:\(it.name)"
            if it.status == "skip" && only == nil {
                if !completed.contains(id) { record(id, "SKIP", it.reason ?? "") }
                continue
            }
            await run(id, timeout: 30) { try Loader.load(it) }
        }
        // 2. functional checks
        await MainActor.run { self.phase = "\(checks.count) functional checks" }
        for c in checks { await run(c.id, timeout: c.timeout, c.run) }
        // 3. coverage
        await MainActor.run { self.phase = "coverage" }
        if !completed.contains("coverage") && only == nil { coverage(m, checks) }
        if only == nil { try? FileManager.default.removeItem(at: progressFile) }
        X86Test.done()
        await MainActor.run { self.phase = "done"; self.current = ""; self.finished = true }
    }

    /// Documents/sdkcov-coverage.json: per framework its load result and functional checks; one summary line
    private func coverage(_ m: Manifest, _ checks: [Check]) {
        var rows: [[String: Any]] = []
        var loaded = 0, testable = 0, withFunc = 0
        let byFw = Dictionary(grouping: checks, by: \.fw)
        for it in m.items {
            let ld = statuses["load:\(it.name)"]
            let fs = (byFw[it.name] ?? []).map { c -> [String: String] in
                let s = statuses[c.id]; return ["check": c.name, "status": s?.0 ?? "?", "detail": s?.1 ?? ""]
            }
            if it.status == "test" { testable += 1; if ld?.0 == "PASS" { loaded += 1 }; if !fs.isEmpty { withFunc += 1 } }
            rows.append(["name": it.name, "kind": it.kind, "load": ld?.0 ?? "?", "loadDetail": ld?.1 ?? "",
                         "functional": fs, "level": it.status == "skip" ? "skip" : (fs.isEmpty ? "load" : "functional")])
        }
        let extra = Set(checks.map(\.fw)).subtracting(m.items.map(\.name)).sorted()  // Swift modules (usr/lib/swift)
        let out: [String: Any] = ["platform": m.platform, "sdk": m.sdk, "runtime": m.runtime,
                                  "os": ProcessInfo.processInfo.operatingSystemVersionString, "items": rows, "swiftModules": extra]
        if let d = try? JSONSerialization.data(withJSONObject: out, options: [.prettyPrinted, .sortedKeys]) {
            try? d.write(to: docs.appendingPathComponent("sdkcov-coverage.json"))
        }
        record("coverage", loaded == testable ? "PASS" : "FAIL",
               "\(m.platform) \(m.sdk): \(m.items.count) SDK entries, \(testable) shipped in the runtime, loaded \(loaded)/\(testable), functional checks for \(withFunc) (+\(extra.count) Swift modules), \(checks.count) functional checks")
    }
}

struct RootView: View {
    @EnvironmentObject var r: Runner
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                Text("sdkcov").font(.headline)
                Text(r.manifest.map { "\($0.platform) · \($0.sdk)" } ?? "").font(.caption)
                Text(r.phase).font(.caption)
                HStack {
                    Text("✓\(r.pass)").foregroundColor(.green)
                    Text("✗\(r.fail)").foregroundColor(.red)
                    Text("–\(r.skip)").foregroundColor(.gray)
                    Text("/\(r.total)")
                }.font(.body.monospacedDigit())
                ProgressView(value: Double(r.pass + r.fail + r.skip), total: Double(max(r.total, 1)))
                Text(r.finished ? "done" : r.current).font(.caption2).lineLimit(1)
                ForEach(Array(r.failures.suffix(40).enumerated()), id: \.offset) { _, f in
                    Text(f).font(.caption2).foregroundColor(.red).lineLimit(2)
                }
            }.padding()
        }
    }
}

@main
struct SDKCovApp: App {
    @StateObject var runner = Runner.shared
    init() { Runner.shared.start() }
    var body: some Scene {
        WindowGroup { RootView().environmentObject(runner) }
        #if os(visionOS)
        // More_visionOS.swift's window / immersive-space / compositor checks open these
        WindowGroup(id: "sdkcov-volume") { SDKCovScenes.volume() }.windowStyle(.volumetric)
        ImmersiveSpace(id: "sdkcov-immersive") { SDKCovScenes.immersive() }
        ImmersiveSpace(id: "sdkcov-compositor") { SDKCovScenes.compositor() }
        #endif
    }
}
