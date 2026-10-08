import Foundation

// Unsent composer text that follows the user between the phone and the Claude desktop window.

/// A chat's unsent text, from whichever device changed it last.
public struct ChatDraft: Codable, Hashable, Sendable {
    public enum Source: String, Codable, Sendable { case phone, desktop }
    public var text: String
    public var source: Source
    /// When the text last changed (for desktop drafts: when the Mac first saw it).
    public var at: Date

    public init(text: String, source: Source, at: Date = Date()) {
        self.text = text; self.source = source; self.at = at
    }
}

/// `POST /v1/chats/{id}/draft`. An empty text clears the phone's draft.
public struct DraftBody: Codable, Sendable {
    public var text: String
    public init(text: String) { self.text = text }
}

public enum DraftMerge {
    /// Longest draft the Mac keeps; longer text is cut.
    public static let maxLength = 20_000

    public static func isBlank(_ s: String) -> Bool { s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    /// What the phone composer should change to, or nil to leave it alone.
    ///
    /// - `local`: the composer text now. `prefilled`: text last filled in from the Mac, while untouched.
    /// - `localAt`: when the user last changed the composer themselves (typing, clearing, sending).
    /// - `remote`: the Mac's draft for the chat. Only desktop drafts are used; phone ones are this phone's echo.
    ///
    /// Text the user typed is never replaced. An untouched prefill follows the desktop text and is
    /// cleared when the desktop draft goes away (sent or deleted there).
    public static func composer(local: String, prefilled: String?, localAt: Date?, remote: ChatDraft?) -> String? {
        let untouched = prefilled != nil && local == prefilled
        guard isBlank(local) || untouched else { return nil }
        guard let r = remote, r.source == .desktop, !isBlank(r.text) else {
            return untouched && !local.isEmpty ? "" : nil
        }
        if r.text == local { return nil }
        if !untouched, let localAt, localAt >= r.at { return nil }   // the user cleared it after that draft
        return r.text
    }
}
