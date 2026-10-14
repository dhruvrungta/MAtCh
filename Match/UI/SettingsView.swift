import SwiftUI

struct SettingsView: View {
    @Bindable var appState: AppState

    var body: some View {
        TabView(selection: $appState.selectedSettingsTab) {
            GeneralSettings(appState: appState)
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag(AppState.SettingsTab.general)
            AccountSettings(appState: appState)
                .tabItem { Label("Account", systemImage: "person.crop.circle") }
                .tag(AppState.SettingsTab.account)
            NetworkSettings(appState: appState)
                .tabItem { Label("Network", systemImage: "wifi") }
                .tag(AppState.SettingsTab.network)
            HistorySettings(sessions: appState.sessions)
                .tabItem { Label("History", systemImage: "clock") }
                .tag(AppState.SettingsTab.history)
            AdvancedSettings(appState: appState)
                .tabItem { Label("Advanced", systemImage: "wrench.and.screwdriver") }
                .tag(AppState.SettingsTab.advanced)
            AboutSettings()
                .tabItem { Label("About", systemImage: "info.circle") }
                .tag(AppState.SettingsTab.about)
        }
        .frame(width: 480)
        .onAppear { appState.refreshKeychainStatus() }
    }
}

private struct GeneralSettings: View {
    let appState: AppState
    @State private var message: String?
    @State private var notificationsAuthorized = true

    var body: some View {
        Form {
            Section {
                Toggle("Sign in automatically", isOn: Binding(
                    get: { appState.autoLoginEnabled },
                    set: { appState.setAutoLogin($0) }
                ))
                Toggle("Open MAtCh when I log in to my Mac", isOn: Binding(
                    get: { appState.launchAtLogin },
                    set: { message = appState.setLaunchAtLogin($0) }
                ))
                .disabled(!appState.launchAtLoginAvailable)
                if !appState.launchAtLoginAvailable {
                    Text("Move MAtCh to your Applications folder to use this.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let message {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }

            if appState.canCheckForUpdates {
                Section {
                    Toggle("Check for updates once a day", isOn: Binding(
                        get: { appState.updateChecksEnabled },
                        set: { appState.setUpdateChecksEnabled($0) }
                    ))
                    Text("MAtCh only reads the latest version number. It sends nothing about you, and never downloads or installs anything by itself.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Section("Notify me when") {
                ForEach(NotificationCategory.allCases, id: \.self) { category in
                    Toggle(category.label, isOn: Binding(
                        get: { appState.notifications[category] ?? true },
                        set: { enabled in
                            appState.setNotification(category, enabled: enabled)
                            Task { notificationsAuthorized = await UserNotifier.isAuthorized() }
                        }
                    ))
                }
                if !notificationsAuthorized {
                    Text("Notifications for MAtCh are turned off in System Settings → Notifications.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .task { notificationsAuthorized = await UserNotifier.isAuthorized() }
    }
}

private struct AccountSettings: View {
    let appState: AppState
    @State private var message: String?
    @State private var savedNote: String?

    var body: some View {
        Form {
            Section("Saved sign-in") {
                if let userId = appState.savedUserId {
                    LabeledContent("Registration number", value: userId)
                } else {
                    Text("Nothing saved yet.")
                        .foregroundStyle(.secondary)
                }
            }

            if appState.keychainApprovalNeeded {
                Section("MAtCh was updated") {
                    Text(StatusCopy.keychainApprovalAdvice)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Unlock") { appState.unlockSavedSignIn() }
                }
            } else {
                Section(appState.savedUserId == nil ? "Add your sign-in" : "Change your sign-in") {
                    CredentialsFields(appState: appState) {
                        savedNote = "Saved."
                        message = nil
                    }
                    if let savedNote {
                        Text(savedNote)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if appState.savedUserId != nil {
                    Section {
                        Button("Remove saved sign-in", role: .destructive) {
                            message = appState.removeCredentials()
                            savedNote = nil
                        }
                        if let message {
                            Text(message)
                                .font(.caption)
                                .foregroundStyle(.red)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct NetworkSettings: View {
    let appState: AppState
    @State private var newName = ""

    var body: some View {
        Form {
            Section {
                Toggle("Show network name", isOn: Binding(
                    get: { appState.showNetworkName },
                    set: { appState.setShowNetworkName($0) }
                ))
                Text("macOS only reveals the Wi-Fi name to apps with Location permission. MAtCh uses it for the name and nothing else.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if appState.showNetworkName {
                    if let name = appState.networkName {
                        LabeledContent("Current network", value: name)
                    } else if appState.location.isDenied {
                        Text("Location permission for MAtCh is turned off in System Settings → Privacy & Security → Location Services.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            Section("Known campus networks") {
                Text("A Wi-Fi name containing any of these counts as a campus network. This only affects what MAtCh shows; it never decides whether to sign in.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(appState.campusNetworkNames, id: \.self) { name in
                    HStack {
                        Text(name)
                        Spacer()
                        Button("Remove") {
                            appState.setCampusNetworkNames(appState.campusNetworkNames.filter { $0 != name })
                        }
                        .buttonStyle(.link)
                    }
                }
                HStack {
                    TextField("Add a name", text: $newName)
                        .onSubmit(addName)
                    Button("Add", action: addName)
                        .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }

            Section {
                LabeledContent("Networks recognised by their router", value: "\(appState.rememberedGatewayCount)")
                Button("Forget them") { appState.forgetCampusGateways() }
                    .disabled(appState.rememberedGatewayCount == 0)
            }
        }
        .formStyle(.grouped)
        .onAppear { appState.refreshNetworkDetails() }
        .onChange(of: appState.location.status) { appState.refreshNetworkDetails() }
    }

    private func addName() {
        appState.setCampusNetworkNames(appState.campusNetworkNames + [newName])
        newName = ""
    }
}

struct HistorySettings: View {
    let sessions: SessionStore
    @State private var confirmingClear = false

    /// Enough to scroll through without making the window slow to open.
    private static let shown = 100

    var body: some View {
        Form {
            if sessions.records.isEmpty {
                Section {
                    Text("No sessions yet. A session is recorded each time MAtCh has been connected for a minute or more.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                Section("Sessions") {
                    ForEach(sessions.records.prefix(Self.shown)) { record in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(record.start.formatted(date: .abbreviated, time: .shortened))
                                Spacer()
                                Text(record.source == .portal ? "Reported by the portal" : "Measured by MAtCh")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Text(StatusCopy.summary(of: record))
                                .font(.callout.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                Section {
                    Text("Figures measured by MAtCh count everything this Mac sent and received over Wi-Fi during the session.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Clear history…", role: .destructive) { confirmingClear = true }
                }
            }
        }
        .formStyle(.grouped)
        .frame(maxHeight: 460)
        .confirmationDialog("Clear the session history?", isPresented: $confirmingClear) {
            Button("Clear history", role: .destructive) { sessions.clear() }
            Button("Cancel", role: .cancel) {}
        }
    }
}

private struct AdvancedSettings: View {
    let appState: AppState
    @State private var copied = false
    @State private var confirmingReset = false
    @State private var message: String?

    var body: some View {
        Form {
            Section("Diagnostics") {
                Text("Copies MAtCh's recent activity log, with your registration number removed, so you can paste it into a bug report. Your password is never in the log.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Copy diagnostics") {
                        Task {
                            await appState.copyDiagnostics()
                            copied = true
                        }
                    }
                    if copied {
                        Text("Copied")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section("Reset") {
                Text("Removes your saved sign-in and puts every setting back to its default.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Reset everything…", role: .destructive) { confirmingReset = true }
                if let message {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("Reset MAtCh?", isPresented: $confirmingReset) {
            Button("Reset everything", role: .destructive) { message = appState.resetEverything() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Your saved sign-in and all settings will be removed.")
        }
    }
}

private struct AboutSettings: View {
    var body: some View {
        VStack(spacing: 8) {
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable()
                .frame(width: 72, height: 72)
            Text("MAtCh")
                .font(.title2.weight(.semibold))
            Text("Version \(Self.version)")
                .foregroundStyle(.secondary)
            Text("Signs you in to the VIT hostel Wi-Fi automatically.")
            Text("Your sign-in stays in your Mac's Keychain and is sent only to the VIT login portal.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Text("MIT License")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(24)
        .frame(maxWidth: .infinity)
    }

    private static var version: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(version) (\(build))"
    }
}
