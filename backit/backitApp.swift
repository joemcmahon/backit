import SwiftUI
import AppKit

@main
struct backitApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings { EmptyView() }  // Required for @main, no window shown
    }
}
