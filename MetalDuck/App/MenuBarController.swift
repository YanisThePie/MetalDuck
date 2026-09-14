//
//  MenuBarController.swift
//  MetalDuck
//
//  Created by Roberto Camargo on 07/11/25.
//

import AppKit
import Foundation
import Sparkle
import SwiftUI

@Observable
final class MenuBarController: NSObject, NSMenuDelegate {
    private var statusItem: NSStatusItem?
    private var preferencesWindow: NSWindow?

    private var currentSourceItem: NSMenuItem?
    private var appleVSRItem: NSMenuItem?
    private var frameInterpolationItem: NSMenuItem?
    private var autoTargetItem: NSMenuItem?
    private var p1440TargetItem: NSMenuItem?
    private var p2160TargetItem: NSMenuItem?
    private var startItem: NSMenuItem?
    private var stopItem: NSMenuItem?

    var appState: AppState
    private weak var updaterController: SPUStandardUpdaterController?

    init(
        appState: AppState,
        updaterController: SPUStandardUpdaterController
    ) {
        self.appState = appState
        self.updaterController = updaterController
        super.init()
        setupMenuBar()
    }

    private func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(
            withLength: NSStatusItem.variableLength
        )

        if let button = statusItem?.button {
            button.image = NSImage(
                systemSymbolName: "sparkles.rectangle.stack",
                accessibilityDescription: "MetalDuck"
            )
            button.image?.isTemplate = true
            button.toolTip = "MetalDuck video enhancement"
        }

        let menu = NSMenu()
        menu.delegate = self

        let sourceItem = NSMenuItem(
            title: "Source: Main Display",
            action: nil,
            keyEquivalent: ""
        )
        sourceItem.isEnabled = false
        menu.addItem(sourceItem)
        currentSourceItem = sourceItem

        menu.addItem(.separator())

        let vsrItem = NSMenuItem(
            title: "Apple Video Super Resolution",
            action: #selector(toggleAppleVSR),
            keyEquivalent: ""
        )
        vsrItem.target = self
        menu.addItem(vsrItem)
        appleVSRItem = vsrItem

        let interpolationItem = NSMenuItem(
            title: "Frame Interpolation",
            action: #selector(toggleFrameInterpolation),
            keyEquivalent: ""
        )
        interpolationItem.target = self
        menu.addItem(interpolationItem)
        frameInterpolationItem = interpolationItem

        let targetItem = NSMenuItem(
            title: "VSR Target",
            action: nil,
            keyEquivalent: ""
        )
        let targetMenu = NSMenu()

        let autoItem = NSMenuItem(
            title: "Auto (Retina display)",
            action: #selector(selectAutoTarget),
            keyEquivalent: ""
        )
        autoItem.target = self
        targetMenu.addItem(autoItem)
        autoTargetItem = autoItem

        let p1440Item = NSMenuItem(
            title: "2560×1440",
            action: #selector(select1440Target),
            keyEquivalent: ""
        )
        p1440Item.target = self
        targetMenu.addItem(p1440Item)
        p1440TargetItem = p1440Item

        let p2160Item = NSMenuItem(
            title: "3840×2160",
            action: #selector(select4KTarget),
            keyEquivalent: ""
        )
        p2160Item.target = self
        targetMenu.addItem(p2160Item)
        p2160TargetItem = p2160Item

        targetItem.submenu = targetMenu
        menu.addItem(targetItem)

        menu.addItem(.separator())

        let start = NSMenuItem(
            title: "Start Capture",
            action: #selector(startCapture),
            keyEquivalent: ""
        )
        start.target = self
        menu.addItem(start)
        startItem = start

        let stop = NSMenuItem(
            title: "Stop Capture",
            action: #selector(stopCapture),
            keyEquivalent: ""
        )
        stop.target = self
        menu.addItem(stop)
        stopItem = stop

        menu.addItem(.separator())

        let preferencesItem = NSMenuItem(
            title: "Preferences…",
            action: #selector(showPreferences),
            keyEquivalent: ","
        )
        preferencesItem.target = self
        menu.addItem(preferencesItem)

        let checkUpdatesItem = NSMenuItem(
            title: "Check for Updates…",
            action: #selector(checkForUpdates),
            keyEquivalent: ""
        )
        checkUpdatesItem.target = self
        menu.addItem(checkUpdatesItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(
            title: "Quit MetalDuck",
            action: #selector(quitApp),
            keyEquivalent: "q"
        )
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem?.menu = menu
        appState.menuBarItem = statusItem
        refreshMenuState()
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        refreshMenuState()
    }

    private func refreshMenuState() {
        let coordinator = AppCoordinator.shared
        let vsrEnabled = coordinator.upscaleSettings.superResolutionEnabled
        let interpolationEnabled =
            coordinator.upscaleSettings.frameInterpolationEnabled

        appleVSRItem?.state = vsrEnabled ? .on : .off
        frameInterpolationItem?.state = interpolationEnabled ? .on : .off

        if #available(macOS 26.0, *) {
            appleVSRItem?.isEnabled = AppleVSRProcessor.isSupported
        } else {
            appleVSRItem?.isEnabled = false
        }

        autoTargetItem?.state =
            coordinator.appleVSRTargetMode == .automatic ? .on : .off
        p1440TargetItem?.state =
            coordinator.appleVSRTargetMode == .p1440 ? .on : .off
        p2160TargetItem?.state =
            coordinator.appleVSRTargetMode == .p2160 ? .on : .off

        startItem?.isEnabled = !appState.isCapturing
        stopItem?.isEnabled = appState.isCapturing

        currentSourceItem?.title = captureSourceTitle(
            for: coordinator.captureSettings
        )

        if let button = statusItem?.button {
            button.contentTintColor =
                appState.isCapturing && (vsrEnabled || interpolationEnabled)
                    ? .systemGreen
                    : nil
            button.toolTip = "MetalDuck — \(coordinator.processingModeLabel)"
        }
    }

    private func captureSourceTitle(
        for settings: CaptureSettings
    ) -> String {
        if let windowID = settings.targetWindowID {
            let options: CGWindowListOption = [.optionIncludingWindow]

            guard let list = CGWindowListCopyWindowInfo(
                options,
                windowID
            ) as? [[CFString: Any]],
            let info = list.first
            else {
                return "Source: Window \(windowID)"
            }

            let owner = info[kCGWindowOwnerName] as? String
            let title = info[kCGWindowName] as? String

            if let owner, let title, !title.isEmpty {
                return "Source: \(owner) — \(title)"
            }

            if let owner {
                return "Source: \(owner)"
            }

            return "Source: Window \(windowID)"
        }

        if let displayID = settings.targetDisplayID {
            return "Source: Display \(displayID)"
        }

        return "Source: Main Display"
    }

    @objc private func toggleAppleVSR() {
        let coordinator = AppCoordinator.shared
        coordinator.setAppleVSREnabled(
            !coordinator.upscaleSettings.superResolutionEnabled
        )
        refreshMenuState()
    }

    @objc private func toggleFrameInterpolation() {
        let coordinator = AppCoordinator.shared
        coordinator.setFrameInterpolationEnabled(
            !coordinator.upscaleSettings.frameInterpolationEnabled
        )
        refreshMenuState()
    }

    @objc private func selectAutoTarget() {
        AppCoordinator.shared.setAppleVSRTargetMode(.automatic)
        refreshMenuState()
    }

    @objc private func select1440Target() {
        AppCoordinator.shared.setAppleVSRTargetMode(.p1440)
        refreshMenuState()
    }

    @objc private func select4KTarget() {
        AppCoordinator.shared.setAppleVSRTargetMode(.p2160)
        refreshMenuState()
    }

    @objc private func checkForUpdates() {
        updaterController?.checkForUpdates(nil)
    }

    @objc private func startCapture() {
        NotificationCenter.default.post(name: .startCapture, object: nil)
        refreshMenuState()
    }

    @objc private func stopCapture() {
        NotificationCenter.default.post(name: .stopCapture, object: nil)
        refreshMenuState()
    }

    @objc private func showPreferences() {
        if preferencesWindow == nil {
            let contentView = PreferencesView(
                captureSettings: Binding(
                    get: { AppCoordinator.shared.captureSettings },
                    set: { AppCoordinator.shared.captureSettings = $0 }
                ),
                upscaleSettings: Binding(
                    get: { AppCoordinator.shared.upscaleSettings },
                    set: { AppCoordinator.shared.upscaleSettings = $0 }
                )
            )

            let window = NSWindow(
                contentRect: NSRect(
                    x: 0,
                    y: 0,
                    width: 600,
                    height: 650
                ),
                styleMask: [
                    .titled,
                    .closable,
                    .miniaturizable,
                    .resizable
                ],
                backing: .buffered,
                defer: false
            )

            window.contentView = NSHostingView(rootView: contentView)
            window.center()
            window.title = "MetalDuck Preferences"
            window.isReleasedWhenClosed = false

            preferencesWindow = window
        }

        preferencesWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func quitApp() {
        NSApplication.shared.terminate(nil)
    }
}

extension Notification.Name {
    static let startCapture = Notification.Name("startCapture")
    static let stopCapture = Notification.Name("stopCapture")
}
