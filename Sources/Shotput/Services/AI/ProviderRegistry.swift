import FoundationModels
import Foundation

struct ProviderChoice: Identifiable, Equatable {
    var id: AIProvider
    var displayName: String
    var isCloud: Bool
    var isEnabled: Bool
    var disabledReason: String?
}

/// Instance state rather than statics, so parallel tests can inject their
/// own answers for Apple Intelligence availability without touching the
/// real `SystemLanguageModel`.
struct ProviderRegistry {
    static let live = ProviderRegistry()

    var appleAvailable: () -> Bool = { SystemLanguageModel.default.isAvailable }
    var appleUnavailableReason: () -> String? = { AppleLocalProvider.currentUnavailableReason() }

    func choices(for settings: AISettings) -> [ProviderChoice] {
        AIProvider.allCases.map { provider in
            switch provider {
            case .appleLocal:
                let available = appleAvailable()
                return ProviderChoice(
                    id: provider,
                    displayName: "Apple on-device",
                    isCloud: false,
                    isEnabled: available,
                    disabledReason: available ? nil : appleUnavailableReason()
                )
            case .ollamaLocal:
                let host = ollamaHost(settings)
                let allowed = allowsEgress(to: host, settings)
                return ProviderChoice(
                    id: provider,
                    displayName: settings.model.isEmpty ? "Ollama" : "\(settings.model) · Ollama",
                    isCloud: false,
                    isEnabled: allowed,
                    disabledReason: allowed ? nil : AIError.offMachineBlocked(host).errorDescription
                )
            case .ollamaCloud:
                return ProviderChoice(
                    id: provider,
                    displayName: settings.model.isEmpty ? "Ollama Cloud" : "\(settings.model) · Ollama Cloud",
                    isCloud: true,
                    isEnabled: settings.sendToCloud,
                    disabledReason: settings.sendToCloud ? nil : "Turn on Send images off this Mac"
                )
            }
        }
    }

    func provider(for settings: AISettings) -> DescriptionProvider? {
        guard settings.aiEnabled else { return nil }
        switch settings.provider {
        case .appleLocal:
            guard appleAvailable() else { return nil }
            return AppleLocalProvider()
        case .ollamaLocal:
            let host = ollamaHost(settings)
            guard allowsEgress(to: host, settings) else { return nil }
            return OllamaProvider(client: OllamaClient(host: host, apiKey: nil), model: settings.model, kind: .ollamaLocal)
        case .ollamaCloud:
            guard settings.sendToCloud, !settings.cloudKey.isEmpty else { return nil }
            return OllamaProvider(client: OllamaClient(host: OllamaClient.cloudHost, apiKey: settings.cloudKey), model: settings.model, kind: .ollamaCloud)
        }
    }

    func blockedReason(for settings: AISettings) -> String? {
        guard settings.aiEnabled else { return AIError.aiDisabled.errorDescription }
        switch settings.provider {
        case .appleLocal:
            return appleAvailable() ? nil : appleUnavailableReason()
        case .ollamaLocal:
            let host = ollamaHost(settings)
            return allowsEgress(to: host, settings) ? nil : AIError.offMachineBlocked(host).errorDescription
        case .ollamaCloud:
            if !settings.sendToCloud { return AIError.cloudBlocked.errorDescription }
            if settings.cloudKey.isEmpty { return AIError.missingCloudKey.errorDescription }
            return nil
        }
    }

    /// `NLEmbedding` is the only embedder, and it is weak: over twelve
    /// descriptions it ranked the right screenshot first for 7 of 12
    /// queries, and unrelated queries scored as high as real ones (51
    /// against 33). Semantic results are a shortlist to be backstopped by
    /// substring matching, not a ranking to be trusted. Nothing here
    /// reaches a network, so the egress gate has nothing to guard.
    func embedder(for settings: AISettings) -> Embedder? {
        AppleEmbedder.make()
    }

    /// The gate is the destination, not the provider case: an Ollama host
    /// that isn't loopback carries the image off this Mac exactly the way
    /// ollama.com does, whether it sits on the LAN or the internet.
    private func allowsEgress(to host: URL, _ settings: AISettings) -> Bool {
        host.isLoopbackHost || settings.sendToCloud
    }

    /// `URL(string:)` percent-encodes nearly any string into a non-nil URL,
    /// so a nil check alone lets "not a url" through; a usable host needs
    /// both a scheme and a host.
    private func ollamaHost(_ settings: AISettings) -> URL {
        guard let url = URL(string: settings.ollamaHost), url.scheme != nil, url.host != nil else {
            return OllamaClient.defaultLocalHost
        }
        return url
    }
}
