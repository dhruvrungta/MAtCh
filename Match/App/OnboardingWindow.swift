import AppKit
import SwiftUI

/// Shows the onboarding window.
///
/// This is an AppKit window rather than a SwiftUI scene because a `Window` scene
/// opens itself at every launch on macOS 14, and onboarding must appear only when
/// it is needed.
@MainActor
final class OnboardingWindow {
    private var window: NSWindow?

    func show(appState: AppState) {
        if window == nil {
            let view = OnboardingView(appState: appState) { [weak self] in self?.close() }
            let window = NSWindow(contentViewController: NSHostingController(rootView: view))
            window.title = "Welcome to MAtCh"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.center()
            self.window = window
        }
        // A menu-bar app is not active, so bring it forward before showing a window.
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    func close() {
        window?.close()
        window = nil
    }
}
