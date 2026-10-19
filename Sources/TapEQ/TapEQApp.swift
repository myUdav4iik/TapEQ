import AppKit
import SwiftUI

/// A menu bar app (no Dock icon, see `LSUIElement` in Info.plist).
@main
struct TapEQApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            PanelView(model: appDelegate.model)
        } label: {
            Image(systemName: appDelegate.model.isPoweredOn ? "waveform" : "waveform.slash")
                .accessibilityLabel("TapEQ")
        }
        .menuBarExtraStyle(.window)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    @MainActor let model = AppModel()

    @MainActor
    func applicationWillTerminate(_ notification: Notification) {
        // Destroying the tap un-mutes every app; the HAL would also clean up when the process exits.
        model.stop()
    }
}
