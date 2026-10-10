import Foundation

/// Runs one search for a character's mind: `claude -p` with only WebSearch and WebFetch, no session saved,
/// no MCP, no hooks prompts, in an empty folder. It can read the web and nothing else.
public enum BuddyMindRunner {
    public enum Failure: Error, Equatable { case noCLI, timedOut, failed(String) }

    public static let tools = ["WebSearch", "WebFetch"]

    /// The command line (after the binary).
    public static func arguments(prompt: String, cfg: BuddyMindConfig) -> [String] {
        var a = ["-p", prompt, "--output-format", "json", "--no-session-persistence", "--strict-mcp-config",
                 "--tools", tools.joined(separator: ","), "--allowedTools"] + tools
        a += ["--permission-mode", "dontAsk", "--model", cfg.model]
        if cfg.maxBudgetUSD > 0 { a += ["--max-budget-usd", String(cfg.maxBudgetUSD)] }
        return a
    }

    public static func environment(base: [String: String], cfg: BuddyMindConfig) -> [String: String] {
        var env = base.filter { !$0.key.hasPrefix("CLAUDE_CODE_") && $0.key != "ANTHROPIC_API_KEY" && $0.key != "CLAUDECODE" }
        env[HeadlessRunner.headlessEnv] = "1"
        if let dir = cfg.claudeConfigDir, !dir.isEmpty { env["CLAUDE_CONFIG_DIR"] = (dir as NSString).expandingTildeInPath }
        return env
    }

    static func binary() -> String? {
        let fm = FileManager.default
        if let out = Shell.run("/bin/zsh", ["-lc", "command -v claude"])?.out.trimmingCharacters(in: .whitespacesAndNewlines),
           !out.isEmpty, fm.isExecutableFile(atPath: out) { return out }
        return nil
    }

    /// Blocking; call it off the main thread.
    public static func run(prompt: String, cfg: BuddyMindConfig, timeout: TimeInterval = 240) -> Result<String, Failure> {
        #if DEBUG
        if ProcessInfo.processInfo.environment["SW_BUDDY_MIND_FAKE"] != nil { return .success(fake(prompt)) }
        #endif
        guard let bin = binary() else { return .failure(.noCLI) }
        let cwd = FileManager.default.temporaryDirectory.appendingPathComponent("claude-watch-buddy", isDirectory: true)
        try? FileManager.default.createDirectory(at: cwd, withIntermediateDirectories: true)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: bin)
        p.arguments = arguments(prompt: prompt, cfg: cfg)
        p.currentDirectoryURL = cwd
        p.environment = environment(base: ProcessInfo.processInfo.environment, cfg: cfg)
        let out = Pipe(), err = Pipe()
        p.standardOutput = out; p.standardError = err; p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch { return .failure(.failed(error.localizedDescription)) }
        var outData = Data()
        let reader = DispatchQueue(label: "buddy.mind.read")
        let done = DispatchSemaphore(value: 0)
        reader.async { outData = out.fileHandleForReading.readDataToEndOfFile(); done.signal() }
        let deadline = Date().addingTimeInterval(timeout)
        while p.isRunning, Date() < deadline { usleep(200_000) }
        if p.isRunning { p.terminate(); return .failure(.timedOut) }
        _ = done.wait(timeout: .now() + 5)
        guard p.terminationStatus == 0 else {
            let e = String(data: err.fileHandleForReading.availableData, encoding: .utf8) ?? ""
            return .failure(.failed(String(e.prefix(300))))
        }
        return .success(String(data: outData, encoding: .utf8) ?? "")
    }

    #if DEBUG
    /// For trying the animations and the notebook without spending anything.
    static func fake(_ prompt: String) -> String {
        sleep(4)
        let a = #"{"topic":"Octopuses have three hearts","finding":"Guess what! An octopus has three hearts and blue blood!","tip":"Two hearts pump blood to the gills and one to the body.","source":"https://example.com/octopus","interest":5,"new":true,"nextInterests":["jellyfish"]}"#
        let env: [String: Any] = ["type": "result", "is_error": false, "result": a]
        return String(data: try! JSONSerialization.data(withJSONObject: env), encoding: .utf8)!
    }
    #endif
}
