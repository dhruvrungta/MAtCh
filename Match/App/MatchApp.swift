import SwiftUI

@main
struct MatchApp: App {
    @State private var environment = AppEnvironment()

    var body: some Scene {
        MenuBarExtra {
            MenuContentView(appState: environment.appState)
        } label: {
            Image(systemName: environment.appState.menuBarSymbol)
        }
        .menuBarExtraStyle(.window)
    }
}
