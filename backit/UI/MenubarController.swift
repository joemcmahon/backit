import AppKit
import Combine
import SwiftUI
import UserNotifications

@MainActor
final class MenubarController: NSObject {
    private let statusItem: NSStatusItem
    private let coordinator: BackupCoordinator
    private let scheduleManager: ScheduleManager
    private let settings: BackupSettings
    private var popover: NSPopover?
    private var settingsWindow: NSWindow?
    private var cancellables = Set<AnyCancellable>()

    init(statusItem: NSStatusItem,
         coordinator: BackupCoordinator,
         scheduleManager: ScheduleManager,
         settings: BackupSettings) {
        self.statusItem      = statusItem
        self.coordinator     = coordinator
        self.scheduleManager = scheduleManager
        self.settings        = settings
        super.init()
        configure()
        observeState()
    }

    private func configure() {
        if let img = NSImage(systemSymbolName: "externaldrive",
                             accessibilityDescription: "Backit") {
            statusItem.button?.image = img
        } else {
            statusItem.button?.title = "B"
        }
        statusItem.button?.target = self
        statusItem.button?.action = #selector(statusButtonClicked(_:))
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }

    private func observeState() {
        coordinator.$isRunning
            .receive(on: DispatchQueue.main)
            .sink { [weak self] running in self?.updateIcon(running: running) }
            .store(in: &cancellables)
    }

    private func updateIcon(running: Bool) {
        let name = running ? "externaldrive.fill" : "externaldrive"
        statusItem.button?.image = NSImage(systemSymbolName: name,
                                           accessibilityDescription: "Backit")
            ?? NSImage(named: NSImage.applicationIconName)
    }

    @objc private func statusButtonClicked(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp {
            let menu = buildMenu()
            statusItem.menu = menu
            statusItem.button?.performClick(nil)
            statusItem.menu = nil
        } else if coordinator.isRunning {
            togglePopover(sender)
        } else {
            openSettings()
        }
    }

    private func togglePopover(_ sender: NSStatusBarButton) {
        if let pop = popover, pop.isShown {
            pop.performClose(nil)
        } else {
            let pop = NSPopover()
            pop.contentSize = NSSize(width: 320, height: 400)
            pop.behavior = .transient
            pop.contentViewController = NSHostingController(rootView: MainPanelView(
                coordinator: coordinator,
                db: (NSApp.delegate as? AppDelegate)?.db
            ))
            pop.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
            self.popover = pop
        }
    }

    @discardableResult
    private func buildMenu() -> NSMenu {
        let menu = NSMenu()

        // Status line
        let statusLine: String
        if let date = coordinator.lastRunDate, let status = coordinator.lastRunStatus {
            let fmt = DateFormatter(); fmt.dateStyle = .short; fmt.timeStyle = .short
            let icon = status == .success ? "✓" : status == .partial ? "⚠" : "✗"
            statusLine = "Last backup: \(fmt.string(from: date)) \(icon)"
        } else {
            statusLine = "No backup yet"
        }
        let statusMenuItem = NSMenuItem(title: statusLine, action: nil, keyEquivalent: "")
        statusMenuItem.isEnabled = false
        menu.addItem(statusMenuItem)

        // Missing tool warnings
        if !CCCJob.isInstalled() {
            let item = NSMenuItem(title: "⚠ Carbon Copy Cloner not found", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }
        if !DropboxJob.isInstalled() {
            let item = NSMenuItem(title: "⚠ rclone not found", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }

        menu.addItem(.separator())

        if coordinator.isRunning {
            let stopItem = NSMenuItem(title: "Stop Backup",
                                      action: #selector(stopBackup), keyEquivalent: "")
            stopItem.target = self
            menu.addItem(stopItem)
        } else {
            let runItem = NSMenuItem(title: "Run Backup Now",
                                      action: #selector(runNow), keyEquivalent: "")
            runItem.target = self
            menu.addItem(runItem)
        }

        let skipItem = NSMenuItem(title: "Skip Tonight's Backup…",
                                   action: #selector(skipTonight), keyEquivalent: "")
        skipItem.target = self
        menu.addItem(skipItem)

        menu.addItem(.separator())

        let settingsItem = NSMenuItem(title: "Settings…",
                                       action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Backit",
                                 action: #selector(NSApplication.terminate(_:)),
                                 keyEquivalent: "q"))

        return menu
    }

    @objc private func runNow() {
        coordinator.runBackup()
    }

    @objc private func stopBackup() {
        coordinator.cancelBackup()
    }

    @objc private func skipTonight() {
        let alert = NSAlert()
        alert.messageText = "Skip Tonight's Backup?"
        alert.informativeText = "You can still run it manually from the menu."
        alert.addButton(withTitle: "Skip")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            settings.skipTonight = true
        }
    }

    @objc private func openSettings() {
        if let existing = settingsWindow, existing.isVisible {
            existing.makeKeyAndOrderFront(nil)
            return
        }
        let win = NSWindow(contentRect: .zero,
                           styleMask: [.titled, .closable],
                           backing: .buffered, defer: false)
        win.title = "Backit Settings"
        win.contentViewController = NSHostingController(rootView: SettingsView(settings: settings))
        win.center()
        win.makeKeyAndOrderFront(nil)
        win.isReleasedWhenClosed = false
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow = win
    }
}
