import SwiftUI
import AppKit

@main
struct backitApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings { EmptyView() }
            .commands {
                CommandGroup(replacing: .appSettings) { }
                CommandGroup(replacing: .help) {
                    Button("backit Help") {
                        NSApp.sendAction(#selector(AppDelegate.openHelpWindow(_:)), to: nil, from: nil)
                    }
                    .keyboardShortcut("/", modifiers: [.command, .shift])
                }
            }
    }
}
