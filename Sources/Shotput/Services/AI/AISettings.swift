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
            cloudKey: ollamaCloudKey,
            ollamaHost: ollamaHost
        )
    }
}
