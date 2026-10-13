import AppKit
import SwiftUI

/// The menu-bar icon.
struct StatusIcon: View {
    struct Appearance: Equatable {
        enum Treatment: Equatable {
            case normal
            case pulsing
            case dimmed
        }

        var symbol: String
        var treatment: Treatment

        init(state: EngineState) {
            switch state {
            case .connected:
                (symbol, treatment) = ("wifi", .normal)
            case .checking, .loggingIn:
                (symbol, treatment) = ("wifi", .pulsing)
            case .failed, .needsCredentials, .portalDetected, .keychainLocked:
                (symbol, treatment) = ("wifi.exclamationmark", .normal)
            case .noWiFi:
                (symbol, treatment) = ("wifi.slash", .normal)
            case .notCampus, .online:
                (symbol, treatment) = ("wifi", .dimmed)
            }
        }
    }

    let appearance: Appearance

    var body: some View {
        switch appearance.treatment {
        case .normal:
            Image(systemName: appearance.symbol)
        case .pulsing:
            Image(systemName: appearance.symbol)
                .symbolEffect(.pulse, options: .repeating)
        case .dimmed:
            // The menu bar ignores SwiftUI opacity, so the transparency is drawn
            // into the template image itself.
            Image(nsImage: Self.dimmedImage(appearance.symbol))
        }
    }

    static func dimmedImage(_ symbol: String, opacity: CGFloat = 0.45) -> NSImage {
        let configuration = NSImage.SymbolConfiguration(pointSize: 15, weight: .regular)
        guard let base = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration)
        else { return NSImage() }

        let image = NSImage(size: base.size, flipped: false) { rect in
            base.draw(in: rect, from: .zero, operation: .sourceOver, fraction: opacity)
            return true
        }
        image.isTemplate = true
        return image
    }
}
