import Foundation

/// Why a WhisperKit model load failed because Hugging Face refused a request (HTTP
/// 401 or 403), worded for the user. Shown under "Load Model" in Settings, and the
/// error text of a job whose transcription needed the model. Any other load failure
/// has no case here and keeps the generic "model not loaded".
enum WhisperKitLoadFailure: LocalizedError, Equatable {
    /// The request carried the saved token. 401 and 403 arrive as the same Hub error,
    /// so this also covers a valid token without access to a gated model.
    case tokenRejected
    /// The request carried no token. The Hub also answers 401 for a repository that
    /// does not exist, hence the hint at the model's name.
    case tokenRequired

    var message: String {
        switch self {
        case .tokenRejected:
            "Hugging Face rejected the saved token. Check that it is valid and has access to this model, "
                + "or remove it to download anonymously."

        case .tokenRequired:
            "Hugging Face refused access without a token. The model may be private or gated "
                + "(save a token under Hugging Face token), or its name may be wrong."
        }
    }

    var errorDescription: String? {
        message
    }

    /// The failure `error` stands for when a Hub request made with a token
    /// (`tokenSent`) or without one failed with it, nil when it is not a refusal.
    static func classify(_ error: any Error, tokenSent: Bool) -> Self? {
        guard isRejectedToken(error) else { return nil }
        return tokenSent ? .tokenRejected : .tokenRequired
    }

    /// Whether `error` is the Hub refusing the request's credentials. WhisperKit
    /// keeps its Hub error type internal, so it is matched by its fully qualified
    /// name, which `WhisperKitLoadFailureTests` pins against the real type.
    private static func isRejectedToken(_ error: any Error) -> Bool {
        String(reflecting: error) == "ArgmaxCore.Hub.HubClientError.authorizationRequired"
    }
}
