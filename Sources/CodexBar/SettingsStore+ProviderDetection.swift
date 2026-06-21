import CodexBarCore
import Foundation

extension SettingsStore {
    func runInitialProviderDetectionIfNeeded(force: Bool = false) {
        guard force || !self.providerDetectionCompleted else { return }
        LoginShellPathCache.shared.captureOnce { [weak self] _ in
            Task { @MainActor in
                await self?.applyProviderDetection()
            }
        }
    }

    func applyProviderDetection() async {
        guard !self.providerDetectionCompleted else { return }
        let codexInstalled = BinaryLocator.resolveCodexBinary() != nil
        let claudeInstalled = BinaryLocator.resolveClaudeBinary() != nil
        let logger = CodexBarLog.logger(LogCategories.providerDetection)

        // If none installed, keep Codex enabled to match previous behavior.
        let noneInstalled = !codexInstalled && !claudeInstalled
        let enableCodex = codexInstalled || noneInstalled
        let enableClaude = claudeInstalled

        logger.info(
            "Provider detection results",
            metadata: [
                "codexInstalled": codexInstalled ? "1" : "0",
                "claudeInstalled": claudeInstalled ? "1" : "0",
            ])
        logger.info(
            "Provider detection enablement",
            metadata: [
                "codex": enableCodex ? "1" : "0",
                "claude": enableClaude ? "1" : "0",
            ])

        self.updateProviderConfig(provider: .codex) { entry in
            entry.enabled = enableCodex
        }
        self.updateProviderConfig(provider: .claude) { entry in
            entry.enabled = enableClaude
        }
        self.providerDetectionCompleted = true
        logger.info("Provider detection completed")
    }
}
