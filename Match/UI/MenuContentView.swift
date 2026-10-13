import SwiftUI

struct MenuContentView: View {
    let appState: AppState
    @State private var showingCredentials = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            if let session = appState.sessions.latest {
                Text(Self.summary(of: session))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let action = appState.primaryAction {
                Button(action.title) {
                    if action == .addCredentials {
                        showingCredentials = true
                    } else {
                        appState.perform(action)
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Toggle("Sign in automatically", isOn: Binding(
                get: { appState.autoLoginEnabled },
                set: { appState.setAutoLogin($0) }
            ))

            Divider()

            if showingCredentials {
                CredentialsForm(appState: appState) { showingCredentials = false }
            } else {
                Button(appState.savedUserId == nil ? "Add credentials…" : "Change credentials…") {
                    showingCredentials = true
                }
            }

            Divider()

            Button("Quit Match") { NSApplication.shared.terminate(nil) }
                .keyboardShortcut("q")
        }
        .padding(16)
        .frame(width: 300, alignment: .leading)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(appState.statusTitle)
                .font(.headline)
            if let detail = appState.statusDetail {
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

    static func summary(of session: PortalSession) -> String {
        let duration = Duration.seconds(session.duration)
            .formatted(.units(allowed: [.hours, .minutes, .seconds], width: .abbreviated))
        let down = session.downloadBytes.formatted(.byteCount(style: .binary))
        let up = session.uploadBytes.formatted(.byteCount(style: .binary))
        return "Last session: \(duration) · ↓ \(down) · ↑ \(up)"
    }
}

/// A plain form for entering the registration number and password.
private struct CredentialsForm: View {
    let appState: AppState
    let onDone: () -> Void

    @State private var userId = ""
    @State private var password = ""
    @State private var message: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Registration number, e.g. \(RegistrationNumber.example)", text: $userId)
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()
            SecureField("Wi-Fi password", text: $password)
                .textFieldStyle(.roundedBorder)
                .onSubmit(save)

            if let message {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("Stored in your Mac's Keychain.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Button("Save", action: save)
                    .keyboardShortcut(.defaultAction)
                Button("Cancel", action: onDone)
                Spacer()
                if appState.savedUserId != nil {
                    Button("Remove", role: .destructive) {
                        message = appState.removeCredentials()
                        if message == nil { onDone() }
                    }
                }
            }
        }
        .onAppear { userId = appState.savedUserId ?? "" }
    }

    private func save() {
        message = appState.saveCredentials(userId: userId, password: password)
        if message == nil {
            password = ""
            onDone()
        }
    }
}
