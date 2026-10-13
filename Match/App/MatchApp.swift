import SwiftUI

@main
struct MatchApp: App {
    @State private var environment = AppEnvironment()

    var body: some Scene {
        MenuBarExtra {
            MenuContentView(appState: environment.appState)
        } label: {
            StatusIcon(appearance: environment.appState.iconAppearance)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(appState: environment.appState)
        }
    }
}
