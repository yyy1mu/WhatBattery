import AppKit

@MainActor
enum AppRelauncher {
    static func relaunch() {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.createsNewApplicationInstance = true

        NSWorkspace.shared.openApplication(
            at: Bundle.main.bundleURL,
            configuration: configuration
        ) { _, error in
            guard error == nil else { return }
            NSApplication.shared.terminate(nil)
        }
    }
}
