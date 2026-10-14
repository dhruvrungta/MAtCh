import SwiftUI

/// The three-step welcome shown on first launch, or whenever no sign-in is saved.
struct OnboardingView: View {
    let appState: AppState
    let onFinish: () -> Void

    @State private var step: Int
    @State private var launchAtLogin: Bool
    @State private var notifications = true
    @State private var message: String?

    init(appState: AppState, startingAt step: Int = 1, onFinish: @escaping () -> Void) {
        self.appState = appState
        self.onFinish = onFinish
        _step = State(initialValue: step)
        _launchAtLogin = State(initialValue: appState.launchAtLoginAvailable)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Step \(step) of 3")
                .font(.caption)
                .foregroundStyle(.secondary)

            switch step {
            case 1: welcome
            case 2: credentials
            default: finishingTouches
            }
        }
        .padding(24)
        .frame(width: 440, alignment: .leading)
    }

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Welcome to MAtCh", systemImage: "wifi")
                .font(.title2.weight(.semibold))
            Text("""
                MAtCh signs you in to the VIT hostel Wi-Fi so you never have to see the login page. \
                It lives in the menu bar, notices when the network asks you to sign in, does it for you, \
                and signs in again when your session runs out.
                """)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Continue") { step = 2 }
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    private var credentials: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Your Wi-Fi sign-in")
                .font(.title2.weight(.semibold))
            Text("Enter the registration number and password you use on the hostel Wi-Fi login page.")
                .fixedSize(horizontal: false, vertical: true)
            CredentialsFields(appState: appState, saveTitle: "Save and continue") { step = 3 }
            Button("Back") { step = 1 }
                .buttonStyle(.link)
        }
    }

    private var finishingTouches: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Finishing touches")
                .font(.title2.weight(.semibold))

            Toggle("Open MAtCh when I log in to my Mac", isOn: $launchAtLogin)
                .disabled(!appState.launchAtLoginAvailable)
            if !appState.launchAtLoginAvailable {
                Text("Move MAtCh to your Applications folder to use this.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Toggle("Tell me when I'm signed in or something goes wrong", isOn: $notifications)

            VStack(alignment: .leading, spacing: 6) {
                Label("Two tips", systemImage: "lightbulb")
                    .font(.subheadline.weight(.semibold))
                Text("""
                    In System Settings → Wi-Fi → Details for the hostel network, set Private Wi-Fi Address \
                    to Fixed. The portal counts each address as a separate device.
                    """)
                Text("""
                    When you join the network, macOS may briefly show its own login window. \
                    It closes by itself once MAtCh has signed you in.
                    """)
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            if let message {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button("Done", action: finish)
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    private func finish() {
        if launchAtLogin, appState.launchAtLoginAvailable, !appState.launchAtLogin {
            message = appState.setLaunchAtLogin(true)
        }
        appState.setAllNotifications(enabled: notifications)
        if message == nil {
            onFinish()
        }
    }
}
