import Foundation
import LocalAuthentication
import Observation

/// Face ID / passcode gate: on launch, on return from the background, and before sensitive commands.
@Observable @MainActor
final class AppLock {
    private static let key = "appLockEnabled"

    var enabled: Bool {
        didSet {
            UserDefaults.standard.set(enabled, forKey: Self.key)
            if !enabled { isLocked = false }
        }
    }
    private(set) var isLocked: Bool
    @ObservationIgnored private var authenticating = false

    init() {
        let on = UserDefaults.standard.object(forKey: Self.key) as? Bool ?? true
        enabled = on
        isLocked = on
    }

    init(previewEnabled: Bool) {
        enabled = previewEnabled
        isLocked = false
    }

    /// Called when the app goes to the background (not on `.inactive`, which Face ID itself triggers).
    func lockIfEnabled() {
        if enabled { isLocked = true }
    }

    /// Pairing just happened in front of the user; there is nothing to protect behind the lock yet.
    func didPair() {
        isLocked = false
    }

    func unlock() async {
        guard isLocked, !authenticating else { return }
        if await authenticate(reason: "Unlock Claude Remote") { isLocked = false }
    }

    /// Asks for Face ID / passcode when the lock is on; always true when it's off.
    func confirm(_ reason: String) async -> Bool {
        guard enabled else { return true }
        return await authenticate(reason: reason)
    }

    private func authenticate(reason: String) async -> Bool {
        let ctx = LAContext()
        var err: NSError?
        // No passcode on the device (e.g. a fresh Simulator): there is nothing to check against.
        guard ctx.canEvaluatePolicy(.deviceOwnerAuthentication, error: &err) else { return true }
        authenticating = true
        defer { authenticating = false }
        do {
            return try await ctx.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
        } catch {
            return false
        }
    }
}
