import Foundation

/// Where the Hugging Face token is kept. Production uses the Keychain; tests
/// inject a store of their own, so they never touch the token saved in the app
/// (the reason is at `AppSettings.huggingFaceTokenStore`).
struct HuggingFaceTokenStore {
    /// The saved token, or nil when none is saved. Reads the secret itself.
    let read: () -> String?
    /// Stores the token, replacing an earlier one. True when it is now stored.
    let save: (String) -> Bool
    /// Removes the token. True when none is left, including when none was saved.
    let delete: () -> Bool
    /// Whether a token is saved, asked without reading it.
    let exists: () -> Bool

    /// A generic password under the app's Keychain service.
    static func keychain(account: String) -> Self {
        Self(
            read: { KeychainHelper.read(key: account) },
            save: { KeychainHelper.save(key: account, value: $0) },
            delete: { KeychainHelper.delete(key: account) },
            exists: { KeychainHelper.exists(key: account) },
        )
    }
}

/// The Hugging Face token for WhisperKit's Hub requests (Settings → Transcription,
/// next to the model). The settings row is write-only: it shows what is being
/// typed and whether a token is saved, never the saved token.
extension AppSettings {
    /// The saved Hugging Face token, `""` when none is saved (anonymous requests).
    ///
    /// The one accessor for the token, also meant for a Hugging Face model
    /// search later. Read it only right before a Hugging Face request is made,
    /// never from a view body or `init`: a test binary reading the app's own
    /// Keychain item raises an authorization prompt that blocks `swift test`.
    var huggingFaceToken: String {
        huggingFaceTokenStore.read() ?? ""
    }

    /// Saves what was typed, trimmed of surrounding whitespace and newlines; an
    /// empty result changes nothing. A saved token clears the field. A failed
    /// save keeps it for a retry and says so, and the saved flag still reports an
    /// older token if one is there.
    func saveHuggingFaceTokenDraft() {
        let token = huggingFaceTokenDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { return }
        if huggingFaceTokenStore.save(token) {
            huggingFaceTokenDraft = ""
            huggingFaceTokenProblem = nil
        } else {
            huggingFaceTokenProblem = "The token could not be saved to the Keychain."
        }
        refreshHuggingFaceTokenSaved()
    }

    func removeHuggingFaceToken() {
        huggingFaceTokenDraft = ""
        if huggingFaceTokenStore.delete() {
            huggingFaceTokenProblem = nil
        } else {
            huggingFaceTokenProblem = "The token could not be removed from the Keychain."
        }
        refreshHuggingFaceTokenSaved()
    }

    /// Asks the store whether a token is saved, without reading it.
    func refreshHuggingFaceTokenSaved() {
        huggingFaceTokenSaved = huggingFaceTokenStore.exists()
    }
}
