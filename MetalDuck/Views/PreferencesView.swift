//
//  PreferencesView.swift
//  MetalDuck
//
//  Created by Roberto Camargo on 07/11/25.
//

import ScreenCaptureKit
import SwiftUI
@preconcurrency import VideoToolbox

struct PreferencesView: View {
    @Binding var captureSettings: CaptureSettings
    @Binding var upscaleSettings: UpscaleSettings

    @State private var targetType = "Display"
    @State private var availableWindows: [(id: CGWindowID, title: String)] = []
    @State private var availableDisplays: [(id: CGDirectDisplayID, name: String)] = []
    @State private var selectedWindowID: CGWindowID?
    @State private var selectedDisplayID: CGDirectDisplayID?
    @State private var isLoading = false
    @State private var showDebugHUD = true
    @State private var showDiagnostics = false

    private var vsrTargetBinding: Binding<AppleVSRTargetMode> {
        Binding(
            get: { AppCoordinator.shared.appleVSRTargetMode },
            set: { mode in
                AppCoordinator.shared.setAppleVSRTargetMode(mode)
                upscaleSettings.targetResolution =
                    AppCoordinator.shared.resolvedAppleVSRTargetResolution()
            }
        )
    }

    var body: some View {
        Form {
            captureSection
            processingSection
            debugSection
        }
        .formStyle(.grouped)
        .frame(width: 430)
        .fixedSize(horizontal: false, vertical: true)
        .onChange(of: upscaleSettings.superResolutionEnabled) { _, enabled in
            AppCoordinator.shared.setAppleVSREnabled(enabled)
        }
        .onChange(of: upscaleSettings.frameInterpolationEnabled) { _, enabled in
            AppCoordinator.shared.setFrameInterpolationEnabled(enabled)
        }
        .onChange(of: upscaleSettings.interpolationMultiplier) { _, _ in
            AppCoordinator.shared.updateUpscaleSettings(upscaleSettings)
            AppCoordinator.shared.resetFrameInterpolator()
        }
        .onChange(of: upscaleSettings.processingResolution) { _, _ in
            AppCoordinator.shared.updateUpscaleSettings(upscaleSettings)
            AppCoordinator.shared.resetFrameInterpolator()
        }
        .onChange(of: captureSettings.frameRate) { _, _ in
            restartCaptureIfNeeded()
        }
        .sheet(isPresented: $showDiagnostics) {
            if #available(macOS 14.0, *) {
                DiagnosticsView()
            }
        }
        .onAppear {
            if captureSettings.targetWindowID != nil {
                targetType = "Window"
                selectedWindowID = captureSettings.targetWindowID
            } else if captureSettings.targetDisplayID != nil {
                targetType = "Display"
                selectedDisplayID = captureSettings.targetDisplayID
            } else {
                targetType = "Display"
            }

            showDebugHUD =
                AppCoordinator.shared.overlayManager?.showDebugOverlay ?? true
            loadAvailableTargets()
        }
    }

    // MARK: - Capture

    private var captureSection: some View {
        Section {
            Picker("Capture Type", selection: $targetType) {
                Text("Display").tag("Display")
                Text("Window").tag("Window")
            }
            .onChange(of: targetType) { _, newValue in
                if newValue == "Window" {
                    captureSettings.targetDisplayID = nil
                } else {
                    captureSettings.targetWindowID = nil
                }
                loadAvailableTargets()
            }

            if targetType == "Window" {
                windowPicker
            } else {
                displayPicker
            }

            Stepper(
                "Capture FPS: \(captureSettings.frameRate)",
                value: $captureSettings.frameRate,
                in: 30...120,
                step: 30
            )

            HStack {
                Button("Refresh") {
                    loadAvailableTargets()
                }

                Button("Content Picker") {
                    if #available(macOS 12.3, *) {
                        AppCoordinator.shared.presentPicker()
                    }
                }
            }
        } header: {
            HeaderView("Capture")
        }
    }

    @ViewBuilder
    private var windowPicker: some View {
        if isLoading {
            Text("Loading windows...")
                .foregroundColor(.secondary)
        } else {
            Picker(
                "Window",
                selection: Binding(
                    get: { selectedWindowID },
                    set: { newValue in
                        selectedWindowID = newValue
                        captureSettings.targetWindowID = newValue
                        captureSettings.targetDisplayID = nil
                    }
                )
            ) {
                Text("Select a window...").tag(nil as CGWindowID?)
                ForEach(availableWindows, id: \.id) { window in
                    Text(window.title).tag(window.id as CGWindowID?)
                }
            }
        }
    }

    @ViewBuilder
    private var displayPicker: some View {
        if isLoading {
            Text("Loading displays...")
                .foregroundColor(.secondary)
        } else {
            Picker(
                "Display",
                selection: Binding(
                    get: { selectedDisplayID },
                    set: { newValue in
                        selectedDisplayID = newValue
                        captureSettings.targetDisplayID = newValue
                        captureSettings.targetWindowID = nil
                    }
                )
            ) {
                Text("Select a display...").tag(nil as CGDirectDisplayID?)
                ForEach(availableDisplays, id: \.id) { display in
                    Text(display.name).tag(display.id as CGDirectDisplayID?)
                }
            }
        }
    }

    // MARK: - Processing

    private var processingSection: some View {
        Section {
            Toggle(
                "Apple Video Super Resolution",
                isOn: $upscaleSettings.superResolutionEnabled
            )

            if upscaleSettings.superResolutionEnabled {
                vsrControls
            }

            Divider()

            Toggle(
                "Frame Interpolation",
                isOn: $upscaleSettings.frameInterpolationEnabled
            )

            if upscaleSettings.frameInterpolationEnabled {
                interpolationControls
            }

            if upscaleSettings.superResolutionEnabled,
               upscaleSettings.frameInterpolationEnabled
            {
                Label(
                    "Combined pipeline: Frame Interpolation → Apple VSR",
                    systemImage: "arrow.trianglehead.2.clockwise.rotate.90"
                )
                .font(.caption)
                .foregroundColor(.secondary)
            }
        } header: {
            HeaderView("Processing")
        }
    }

    @ViewBuilder
    private var vsrControls: some View {
        if #available(macOS 26.0, *) {
            if VTLowLatencySuperResolutionScalerConfiguration.isSupported {
                Label(
                    "Apple VideoToolbox VSR is available on this Mac.",
                    systemImage: "checkmark.circle.fill"
                )
                .font(.caption)
                .foregroundColor(.green)
            } else {
                Label(
                    "Apple VideoToolbox VSR is not supported on this Mac.",
                    systemImage: "xmark.circle.fill"
                )
                .font(.caption)
                .foregroundColor(.red)
            }

            Picker("VSR Target", selection: vsrTargetBinding) {
                Text("Auto (Retina display)")
                    .tag(AppleVSRTargetMode.automatic)
                Text("2560×1440")
                    .tag(AppleVSRTargetMode.p1440)
                Text("3840×2160")
                    .tag(AppleVSRTargetMode.p2160)
            }

            if AppCoordinator.shared.appleVSRTargetMode == .automatic {
                let target = AppCoordinator.shared.resolvedAppleVSRTargetResolution()
                Text(
                    "Auto target: \(Int(target.width))×\(Int(target.height))"
                )
                .font(.caption)
                .foregroundColor(.secondary)
            }

            Text(
                "MetalDuck automatically chooses the largest model input and "
                    + "scale factor accepted by Apple's low-latency ML scaler."
            )
            .font(.caption)
            .foregroundColor(.secondary)
        } else {
            Label(
                "Apple Video Super Resolution requires macOS 26 or later.",
                systemImage: "exclamationmark.triangle"
            )
            .font(.caption)
            .foregroundColor(.orange)
        }
    }

    private var interpolationControls: some View {
        Group {
            Picker(
                "Processing Resolution",
                selection: $upscaleSettings.processingResolution
            ) {
                ForEach(ProcessingResolution.allCases, id: \.self) { resolution in
                    Text(resolution.rawValue).tag(resolution)
                }
            }

            resolutionWarning

            Stepper(
                "Multiplier: \(upscaleSettings.interpolationMultiplier)x",
                value: $upscaleSettings.interpolationMultiplier,
                in: 2...4,
                step: 1
            )

            if upscaleSettings.interpolationMultiplier > 2 {
                Label(
                    "Multipliers above 2x may increase latency or reduce quality. "
                        + "2x is recommended.",
                    systemImage: "exclamationmark.triangle"
                )
                .font(.caption)
                .foregroundColor(.orange)
            }

            Text(
                "\(captureSettings.frameRate) fps capture → "
                    + "\(upscaleSettings.targetFrameRate(sourceFrameRate: captureSettings.frameRate)) fps output"
            )
            .font(.caption)
            .foregroundColor(.secondary)
        }
    }

    // MARK: - Debug

    private var debugSection: some View {
        Section {
            Toggle("Show Debug HUD", isOn: $showDebugHUD)
                .onChange(of: showDebugHUD) { _, newValue in
                    AppCoordinator.shared.setDebugOverlay(newValue)
                }

            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Button("Run Device Diagnostics...") {
                    showDiagnostics = true
                }
                Text("Help us improve the app")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        } header: {
            HeaderView("Debug")
        }
    }

    // MARK: - Resolution Warning

    @ViewBuilder
    private var resolutionWarning: some View {
        let database = DeviceCapabilityDatabase.shared
        let support = database.frameInterpolationSupport(
            for: upscaleSettings.processingResolution
        )
        let recommended = database.recommendedFrameInterpolationResolution()

        switch support {
        case .knownUnsupported:
            Label(
                "Not supported on this device — a lower resolution will be "
                    + "selected automatically.",
                systemImage: "xmark.circle"
            )
            .font(.caption)
            .foregroundColor(.red)

        case .unknown:
            Label(
                "Support is unknown. MetalDuck will fall back automatically "
                    + "if the selected resolution fails.",
                systemImage: "questionmark.circle"
            )
            .font(.caption)
            .foregroundColor(.orange)

        case .noData:
            Label(
                "No data for this device yet. Run Diagnostics to contribute.",
                systemImage: "info.circle"
            )
            .font(.caption)
            .foregroundColor(.secondary)

        case .knownSupported:
            if let recommended,
               recommended != upscaleSettings.processingResolution
            {
                Label(
                    "Recommended for this device: \(recommended.rawValue)",
                    systemImage: "lightbulb"
                )
                .font(.caption)
                .foregroundColor(.secondary)
            }
        }
    }

    private func restartCaptureIfNeeded() {
        guard AppCoordinator.shared.appState.isCapturing else { return }

        Task {
            await AppCoordinator.shared.stopCapture()
            await AppCoordinator.shared.startCapture()
        }
    }

    @available(macOS 12.3, *)
    private func loadAvailableTargets() {
        isLoading = true

        Task {
            if targetType == "Window" {
                let windows = await ScreenCaptureManager.getAvailableWindows()

                await MainActor.run {
                    availableWindows = windows.compactMap { window in
                        guard window.isOnScreen,
                              window.frame.width > 100,
                              window.frame.height > 100
                        else {
                            return nil
                        }

                        let appName = window.owningApplication?.applicationName
                        let title = window.title?.isEmpty == false
                            ? window.title!
                            : nil

                        let displayName: String
                        if let title, let appName {
                            displayName = "\(appName) — \(title)"
                        } else if let appName {
                            displayName = appName
                        } else {
                            return nil
                        }

                        return (id: window.windowID, title: displayName)
                    }
                    isLoading = false
                }
            } else {
                let displays = await ScreenCaptureManager.getAvailableDisplays()

                await MainActor.run {
                    availableDisplays = displays.map { display in
                        let displayID = display.displayID
                        let width = Int(display.width)
                        let height = Int(display.height)
                        let name =
                            "Display \(displayID) (\(width)x\(height))"
                        return (id: displayID, name: name)
                    }
                    isLoading = false
                }
            }
        }
    }
}
