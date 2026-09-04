import Foundation

/// Value-type mirror of the AI fields on `SettingsStore`, so the queue and
/// registry can be built and tested without a real `SettingsStore`.
struct AISettings: Equatable {
    var aiEnabled: Bool
    var provider: AIProvider
    var model: String
    var sendToCloud: Bool
    var cloudKey: String
    var ollamaHost: String
}

extension SettingsStore {
    var ai: AISettings {
        AISettings(
            aiEnabled: aiEnabled,
            provider: aiProvider,
            model: aiModel,
            sendToCloud: sendToCloud,
            // Reading the key is a keychain call that can block on an ACL
            // dialog, and `AIQueue` asks for this from `ShotputApp.init()`,
            // before there is a window to explain the wait. Only the cloud
            // provider ever uses the key, so only it pays for the read.
            cloudKey: aiProvider.sendsToCloud ? ollamaCloudKey : "",
            ollamaHost: ollamaHost
        )
    }
}
