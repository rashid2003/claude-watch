import Foundation

/// Types a reply into the terminal a chat is open in, so the phone can answer a live `claude` without a
/// second writer on the transcript. Tries tmux, then iTerm2, then Terminal.app, matching by the tty of
/// the chat's `claude` process. The text goes in as a bracketed paste (multi-line stays one message),
/// then Return.
public struct TerminalInjector: Sendable {
    public typealias Exec = @Sendable (_ launch: String, _ args: [String]) -> (status: Int32, out: String)

    public static let unsupportedMessage =
        "Can't type into this terminal. Use Terminal, iTerm2 or tmux for chats you want to reply to from the phone"
    public static let waitingMessage = "Claude is waiting on a prompt in the terminal. Answer it there first"

    public static let stopInTerminal = RetryError(message: "Stop this chat in the terminal on the Mac", permanent: true)

    private let exec: Exec
    private let tmuxPath: String?
    private let appRunning: @Sendable (String) -> Bool

    public init(exec: @escaping Exec = Self.run, tmuxPath: String? = Self.findTmux(),
                appRunning: @escaping @Sendable (String) -> Bool = Self.isRunning) {
        self.exec = exec; self.tmuxPath = tmuxPath; self.appRunning = appRunning
    }

    /// The live registry entry of the `claude` process holding this chat open.
    static func entry(for session: SessionInfo, in dataDir: URL,
                             isAlive: (RegistryEntry) -> Bool = TerminalSessionIndex.processAlive) -> RegistryEntry? {
        let dir = dataDir.appendingPathComponent("sessions")
        let ids = Set([session.cliSessionId, session.id].compactMap { $0 })
        return ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
            .filter { $0.hasSuffix(".json") }
            .compactMap { JSONFile.object(at: dir.appendingPathComponent($0)).flatMap(RegistryEntry.parse) }
            .filter { ids.contains($0.sessionId) && !$0.isDesktop && $0.isInteractive && isAlive($0) }
            .max { ($0.updatedAt ?? .distantPast) < ($1.updatedAt ?? .distantPast) }
    }

    public func send(_ text: String, session: SessionInfo, dataDir: URL) -> Result<String, RetryError> {
        deliver(Self.sanitize(text), bracketed: true, session: session, dataDir: dataDir)
    }

    /// Presses Esc in the chat's terminal: interrupts a turn Claude is working on.
    public func interrupt(session: SessionInfo, dataDir: URL) -> Result<String, RetryError> {
        deliver("\u{1B}", bracketed: false, session: session, dataDir: dataDir)
    }

    private func deliver(_ body: String, bracketed: Bool, session: SessionInfo, dataDir: URL) -> Result<String, RetryError> {
        guard let e = Self.entry(for: session, in: dataDir) else {
            return .failure(RetryError(message: "That terminal chat isn't running any more. Try again", permanent: false))
        }
        guard let tty = tty(pid: e.pid) else {
            return .failure(RetryError(message: "Couldn't find that chat's terminal", permanent: true))
        }
        if let pane = tmuxPane(tty: tty) {
            return bracketed ? paste(tmux: pane, body) : key(tmux: pane, "Escape")
        }
        for app in [Self.iTerm, Self.terminalApp] where appRunning(app.process) {
            switch type(app: app, tty: tty, body, bracketed: bracketed) {
            case .found: return .success("Typed into \(app.name)")
            case .failed(let why): return .failure(RetryError(message: why))
            case .notHere: continue
            }
        }
        return .failure(RetryError(message: Self.unsupportedMessage, permanent: true))
    }

    // MARK: tty / tmux

    func tty(pid: Int32) -> String? {
        let r = exec("/bin/ps", ["-o", "tty=", "-p", String(pid)])
        let t = r.out.trimmingCharacters(in: .whitespacesAndNewlines)
        guard r.status == 0, !t.isEmpty, t != "??", t != "?" else { return nil }
        return t.hasPrefix("/dev/") ? t : "/dev/" + t
    }

    func tmuxPane(tty: String) -> String? {
        guard let tmux = tmuxPath else { return nil }
        let r = exec(tmux, ["list-panes", "-a", "-F", "#{pane_tty} #{pane_id}"])
        guard r.status == 0 else { return nil }
        return Self.pane(in: r.out, tty: tty)
    }

    static func pane(in listing: String, tty: String) -> String? {
        for line in listing.split(separator: "\n") {
            let f = line.split(separator: " ")
            if f.count == 2, f[0] == tty { return String(f[1]) }
        }
        return nil
    }

    private func key(tmux pane: String, _ name: String) -> Result<String, RetryError> {
        guard let tmux = tmuxPath else { return .failure(RetryError(message: Self.unsupportedMessage, permanent: true)) }
        let r = exec(tmux, ["send-keys", "-t", pane, name])
        return r.status == 0 ? .success("Interrupted in tmux") : .failure(RetryError(message: "tmux refused: \(r.out)"))
    }

    private func paste(tmux pane: String, _ body: String) -> Result<String, RetryError> {
        guard let tmux = tmuxPath else { return .failure(RetryError(message: Self.unsupportedMessage, permanent: true)) }
        let buf = "claudewatch-\(UUID().uuidString.prefix(8))"
        var r = exec(tmux, ["set-buffer", "-b", buf, "--", body])
        if r.status == 0 { r = exec(tmux, ["paste-buffer", "-p", "-d", "-b", buf, "-t", pane]) }
        if r.status == 0 { r = exec(tmux, ["send-keys", "-t", pane, "Enter"]) }
        return r.status == 0 ? .success("Typed into tmux") : .failure(RetryError(message: "tmux refused the reply: \(r.out)"))
    }

    // MARK: iTerm2 / Terminal.app

    struct App: Equatable { var name: String; var process: String }
    static let iTerm = App(name: "iTerm2", process: "iTerm2")
    static let terminalApp = App(name: "Terminal", process: "Terminal")

    enum Typed: Equatable { case found, notHere, failed(String) }

    private func type(app: App, tty: String, _ body: String, bracketed: Bool) -> Typed {
        let r = exec("/usr/bin/osascript", ["-e", Self.script(app: app, bracketed: bracketed), tty, body])
        let out = r.out.trimmingCharacters(in: .whitespacesAndNewlines)
        if r.status != 0 {
            return .failed(out.contains("-1743") || out.contains("not allowed")
                           ? "Allow Session Watch to control \(app.name) in System Settings → Privacy & Security → Automation"
                           : "\(app.name) refused the reply: \(out)")
        }
        return out == "ok" ? .found : .notHere
    }

    /// Finds the tab/session by tty and writes the bracketed paste. `write text` / `do script` add the Return.
    static func script(app: App, bracketed: Bool = true) -> String {
        let paste = bracketed ? """
            set esc to ASCII character 27
            set payload to esc & "[200~" & body & esc & "[201~"
            """ : "set payload to body"
        if app == iTerm {
            return """
            on run argv
              set theTTY to item 1 of argv
              set body to item 2 of argv
              \(paste)
              tell application "iTerm2"
                repeat with w in windows
                  repeat with t in tabs of w
                    repeat with s in sessions of t
                      if tty of s is theTTY then
                        tell s to write text payload\(bracketed ? "" : " newline NO")
                        return "ok"
                      end if
                    end repeat
                  end repeat
                end repeat
              end tell
              return "none"
            end run
            """
        }
        return """
        on run argv
          set theTTY to item 1 of argv
          set body to item 2 of argv
          \(paste)
          tell application "Terminal"
            repeat with w in windows
              repeat with t in tabs of w
                if tty of t is theTTY then
                  do script payload in t
                  return "ok"
                end if
              end repeat
            end repeat
          end tell
          return "none"
        end run
        """
    }

    /// A pasted escape would close the paste early and let the rest run as keystrokes.
    static func sanitize(_ text: String) -> String {
        text.replacingOccurrences(of: "\u{1B}", with: "")
            .replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: System

    public static func findTmux() -> String? {
        ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux", "/usr/bin/tmux"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    @Sendable public static func isRunning(_ process: String) -> Bool {
        run("/usr/bin/pgrep", ["-x", process]).status == 0
    }

    @Sendable public static func run(_ launch: String, _ args: [String]) -> (status: Int32, out: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: launch)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe; p.standardError = pipe
        do { try p.run() } catch { return (-1, "\(error)") }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}
