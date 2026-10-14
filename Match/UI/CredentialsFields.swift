import SwiftUI

/// The registration number and password fields, shared by onboarding and Settings.
struct CredentialsFields: View {
    let appState: AppState
    var saveTitle = "Save"
    var onSaved: () -> Void = {}

    @State private var userId = ""
    @State private var password = ""
    @State private var message: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Inside a form the title becomes the label; elsewhere only the prompt shows.
            TextField(
                "Registration number",
                text: $userId,
                prompt: Text("Registration number, e.g. \(RegistrationNumber.example)")
            )
            .textFieldStyle(.roundedBorder)
            .autocorrectionDisabled()
            SecureField("Wi-Fi password", text: $password, prompt: Text("Wi-Fi password"))
                .textFieldStyle(.roundedBorder)
                .onSubmit(save)

            if let message {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Label("Stored in your Mac's Keychain", systemImage: "lock")
                .font(.caption)
                .foregroundStyle(.secondary)

            Button(saveTitle, action: save)
                .keyboardShortcut(.defaultAction)
        }
        .onAppear { userId = appState.savedUserId ?? "" }
    }

    private func save() {
        message = appState.saveCredentials(userId: userId, password: password)
        if message == nil {
            password = ""
            onSaved()
        }
    }
}
