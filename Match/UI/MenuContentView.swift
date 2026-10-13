import SwiftUI

struct MenuContentView: View {
    let appState: AppState
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            if appState.showsUnlockReminder {
                unlockReminder
            }

            if let action = appState.primaryAction {
                Button(action.title) { run(action) }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
            }

            Toggle("Sign in automatically", isOn: Binding(
                get: { appState.autoLoginEnabled },
                set: { appState.setAutoLogin($0) }
            ))

            if let session = appState.sessions.latest {
                Text("Last session: \(StatusCopy.summary(of: session))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Divider()

            HStack {
                Button("Settings…") { showSettings(.general) }
                    .keyboardShortcut(",")
                Spacer()
                Button("Quit Match") { NSApplication.shared.terminate(nil) }
                    .keyboardShortcut("q")
            }
        }
        .padding(16)
        .frame(width: 300, alignment: .leading)
        .onAppear { appState.refreshNetworkDetails() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            // Re-evaluated periodically so "Connected · 12m" keeps up.
            TimelineView(.periodic(from: .now, by: 30)) { context in
                Text(StatusCopy.title(for: appState.engineState, now: context.date))
                    .font(.headline)
            }
            if let name = appState.networkName {
                Text(name)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            if let detail = StatusCopy.detail(for: appState.engineState) {
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if appState.usingMockPortal {
                Text("Using the mock portal")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }

    private var unlockReminder: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Match was updated")
                .font(.subheadline.weight(.semibold))
            Text(StatusCopy.keychainApprovalAdvice)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Unlock") { appState.unlockSavedSignIn() }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
    }

    private func run(_ action: AppState.PrimaryAction) {
        if action == .addCredentials {
            showSettings(.account)
        } else {
            appState.perform(action)
        }
    }

    private func showSettings(_ tab: AppState.SettingsTab) {
        appState.selectedSettingsTab = tab
        // A menu-bar app is not active, so its windows open behind everything
        // unless it is activated first.
        NSApp.activate()
        openSettings()
    }
}
