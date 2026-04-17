import CodexBarCore
import KeyboardShortcuts
import SwiftUI

@MainActor
struct AdvancedPane: View {
    @Bindable var settings: SettingsStore
    @State private var isInstallingCLI = false
    @State private var cliStatus: String?

    @State private var claudeProxyProfiles: [ClaudeProxyProfile] = []
    @State private var claudeProxyActiveProfileID: UUID?

    private var activeClaudeProxyProfile: ClaudeProxyProfile? {
        guard let id = self.claudeProxyActiveProfileID else { return self.claudeProxyProfiles.first }
        return self.claudeProxyProfiles.first(where: { $0.id == id }) ?? self.claudeProxyProfiles.first
    }

    private var claudeProxyStatusText: String {
        guard let profile = self.activeClaudeProxyProfile else {
            return "Currently sending usage requests to api.anthropic.com."
        }
        let trimmed = profile.trimmedBaseURL
        if trimmed.isEmpty {
            return "Active profile \"\(profile.name)\" has no Base URL — falling back to api.anthropic.com."
        }
        return "Active profile \"\(profile.name)\" → \(trimmed)/api/oauth/usage."
    }

    var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 16) {
                SettingsSection(contentSpacing: 8) {
                    Text("Keyboard shortcut")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)
                    HStack(alignment: .center, spacing: 12) {
                        Text("Open menu")
                            .font(.body)
                        Spacer()
                        KeyboardShortcuts.Recorder(for: .openMenu)
                    }
                    Text("Trigger the menu bar menu from anywhere.")
                        .font(.footnote)
                        .foregroundStyle(.tertiary)
                }

                Divider()

                SettingsSection(contentSpacing: 10) {
                    HStack(spacing: 12) {
                        Button {
                            Task { await self.installCLI() }
                        } label: {
                            if self.isInstallingCLI {
                                ProgressView().controlSize(.small)
                            } else {
                                Text("Install CLI")
                            }
                        }
                        .disabled(self.isInstallingCLI)

                        if let status = self.cliStatus {
                            Text(status)
                                .font(.footnote)
                                .foregroundStyle(.tertiary)
                                .lineLimit(2)
                        }
                    }
                    Text("Symlink CodexBarCLI to /usr/local/bin and /opt/homebrew/bin as codexbar.")
                        .font(.footnote)
                        .foregroundStyle(.tertiary)
                }

                Divider()

                SettingsSection(contentSpacing: 10) {
                    PreferenceToggleRow(
                        title: "Show Debug Settings",
                        subtitle: "Expose troubleshooting tools in the Debug tab.",
                        binding: self.$settings.debugMenuEnabled)
                    PreferenceToggleRow(
                        title: "Surprise me",
                        subtitle: "Check if you like your agents having some fun up there.",
                        binding: self.$settings.randomBlinkEnabled)
                }

                Divider()

                SettingsSection(contentSpacing: 10) {
                    PreferenceToggleRow(
                        title: "Hide personal information",
                        subtitle: "Obscure email addresses in the menu bar and menu UI.",
                        binding: self.$settings.hidePersonalInfo)
                }

                Divider()

                SettingsSection(
                    title: "Claude OAuth Proxy",
                    caption: """
                    Route Claude usage lookups through private OAuth proxies (e.g. Cloudflare \
                    Workers that already hold the real refresh token). Add one profile per \
                    account/endpoint and pick the active one below. Empty list falls back to \
                    api.anthropic.com. Environment variables CODEXBAR_CLAUDE_USAGE_BASE_URL \
                    and CODEXBAR_CLAUDE_OAUTH_TOKEN override the active profile when set.
                    """) {
                        if self.claudeProxyProfiles.isEmpty {
                            Text("No proxy profiles yet — Claude usage will talk to api.anthropic.com.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        } else {
                            VStack(alignment: .leading, spacing: 10) {
                                ForEach(self.claudeProxyProfileBindings(), id: \.wrappedValue.id) { binding in
                                    self.claudeProxyProfileRow(binding: binding)
                                }
                            }
                        }

                        HStack {
                            Button("+ Add Profile") {
                                self.addClaudeProxyProfile()
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)

                            Spacer()
                        }

                        Text(self.claudeProxyStatusText)
                            .font(.footnote)
                            .foregroundStyle(.tertiary)
                    }

                Divider()

                SettingsSection(
                    title: "Keychain access",
                    caption: """
                    Disable all Keychain reads and writes. Browser cookie import is unavailable; paste Cookie \
                    headers manually in Providers.
                    """) {
                        PreferenceToggleRow(
                            title: "Disable Keychain access",
                            subtitle: "Prevents any Keychain access while enabled.",
                            binding: self.$settings.debugDisableKeychainAccess)
                    }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .onAppear {
            self.reloadClaudeProxyProfiles()
        }
    }
}

extension AdvancedPane {
    private func reloadClaudeProxyProfiles() {
        self.claudeProxyProfiles = ClaudeProxyProfileStore.loadProfiles()
        self.claudeProxyActiveProfileID = ClaudeProxyProfileStore.activeProfileID()
            ?? self.claudeProxyProfiles.first?.id
    }

    private func persistClaudeProxyProfiles() {
        ClaudeProxyProfileStore.saveProfiles(self.claudeProxyProfiles)
        ClaudeProxyProfileStore.setActiveProfileID(self.claudeProxyActiveProfileID)
    }

    private func addClaudeProxyProfile() {
        let nextIndex = self.claudeProxyProfiles.count + 1
        let profile = ClaudeProxyProfile(
            name: "Profile \(nextIndex)",
            baseURL: "",
            token: "")
        self.claudeProxyProfiles.append(profile)
        if self.claudeProxyActiveProfileID == nil {
            self.claudeProxyActiveProfileID = profile.id
        }
        self.persistClaudeProxyProfiles()
    }

    private func deleteClaudeProxyProfile(id: UUID) {
        self.claudeProxyProfiles.removeAll(where: { $0.id == id })
        if self.claudeProxyActiveProfileID == id {
            self.claudeProxyActiveProfileID = self.claudeProxyProfiles.first?.id
        }
        self.persistClaudeProxyProfiles()
    }

    private func setActiveClaudeProxyProfile(id: UUID) {
        self.claudeProxyActiveProfileID = id
        self.persistClaudeProxyProfiles()
    }

    private func claudeProxyProfileBindings() -> [Binding<ClaudeProxyProfile>] {
        self.claudeProxyProfiles.indices.map { index in
            Binding<ClaudeProxyProfile>(
                get: { self.claudeProxyProfiles[index] },
                set: { newValue in
                    guard self.claudeProxyProfiles.indices.contains(index) else { return }
                    self.claudeProxyProfiles[index] = newValue
                    self.persistClaudeProxyProfiles()
                })
        }
    }

    @ViewBuilder
    private func claudeProxyProfileRow(binding: Binding<ClaudeProxyProfile>) -> some View {
        let profile = binding.wrappedValue
        let isActive = (self.claudeProxyActiveProfileID ?? self.claudeProxyProfiles.first?.id) == profile.id

        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 8) {
                Button {
                    self.setActiveClaudeProxyProfile(id: profile.id)
                } label: {
                    Image(systemName: isActive ? "largecircle.fill.circle" : "circle")
                        .foregroundStyle(isActive ? Color.accentColor : .secondary)
                }
                .buttonStyle(.plain)
                .help(isActive ? "Active profile" : "Set as active")

                TextField("Name", text: binding.name)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 140)

                TextField("https://cc.example.com", text: binding.baseURL)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()

                Button {
                    self.deleteClaudeProxyProfile(id: profile.id)
                } label: {
                    Image(systemName: "trash")
                        .foregroundStyle(.red)
                }
                .buttonStyle(.plain)
                .help("Delete this profile")
            }

            HStack(alignment: .center, spacing: 8) {
                Text("Token")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 44, alignment: .trailing)
                SecureField("Proxy API key or OAuth access token", text: binding.token)
                    .textFieldStyle(.roundedBorder)
            }
            .padding(.leading, 24)
        }
        .padding(8)
        .background(isActive
            ? Color.accentColor.opacity(0.08)
            : Color.secondary.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}

extension AdvancedPane {
    private func installCLI() async {
        if self.isInstallingCLI { return }
        self.isInstallingCLI = true
        defer { self.isInstallingCLI = false }

        let helperURL = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/CodexBarCLI")
        let fm = FileManager.default
        guard fm.fileExists(atPath: helperURL.path) else {
            self.cliStatus = "CodexBarCLI not found in app bundle."
            return
        }

        let destinations = [
            "/usr/local/bin/codexbar",
            "/opt/homebrew/bin/codexbar",
        ]

        var results: [String] = []
        for dest in destinations {
            let dir = (dest as NSString).deletingLastPathComponent
            guard fm.fileExists(atPath: dir) else { continue }
            guard fm.isWritableFile(atPath: dir) else {
                results.append("No write access: \(dir)")
                continue
            }

            if fm.fileExists(atPath: dest) {
                if Self.isLink(atPath: dest, pointingTo: helperURL.path) {
                    results.append("Installed: \(dir)")
                } else {
                    results.append("Exists: \(dir)")
                }
                continue
            }

            do {
                try fm.createSymbolicLink(atPath: dest, withDestinationPath: helperURL.path)
                results.append("Installed: \(dir)")
            } catch {
                results.append("Failed: \(dir)")
            }
        }

        self.cliStatus = results.isEmpty
            ? "No writable bin dirs found."
            : results.joined(separator: " · ")
    }

    private static func isLink(atPath path: String, pointingTo destination: String) -> Bool {
        guard let link = try? FileManager.default.destinationOfSymbolicLink(atPath: path) else { return false }
        let dir = (path as NSString).deletingLastPathComponent
        let resolved = URL(fileURLWithPath: link, relativeTo: URL(fileURLWithPath: dir))
            .standardizedFileURL
            .path
        return resolved == destination
    }
}
