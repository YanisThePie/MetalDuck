//
//  AppCoordinator.swift
//  MetalDuck
//
//  Created by Roberto Camargo on 07/11/25.
//

import AppKit
import CoreMedia
import CoreVideo
import Foundation
import ScreenCaptureKit
import Sparkle

@MainActor
@Observable
class AppCoordinator {
    static let shared = AppCoordinator()

    var appState = AppState()
    var captureSettings = CaptureSettings()
    var upscaleSettings = UpscaleSettings()
    var appleVSRTargetMode: AppleVSRTargetMode = .automatic

    private var appleVSRProcessor: AppleVSRProcessor?
    private(set) var overlayManager: OverlayManager?
    private var captureManager: ScreenCaptureManager?
    private var menuBarController: MenuBarController?
    private var captureTask: Task<Void, Never>?
    private let updaterDelegate = UpdaterDelegate()
    private var updaterController: SPUStandardUpdaterController?

    @available(macOS 14.0, *)
    private var interpolator: RealTimeFrameInterpolation?

    private var frameCount = 0
    private var lastFPSTime = Date()
    private var interpolatedFrameCount = 0
    private var passthroughFrameCount = 0
    private var sourceFrameCount = 0
    private var currentSourceFPS: Double = 0
    private var lastFrameTimestamp: CMTime?
    private var currentProcessingResolution: CGSize?
    private var hasConfiguredContentRatio = false

    init() {
        setupComponents()
        setupNotifications()
    }

    private func setupComponents() {
        if #available(macOS 26.0, *) {
            appleVSRProcessor = AppleVSRProcessor(
                targetResolution: resolvedAppleVSRTargetResolution()
            )
        }

        overlayManager = OverlayManager()

        let controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: updaterDelegate,
            userDriverDelegate: nil
        )
        updaterController = controller
        menuBarController = MenuBarController(
            appState: appState,
            updaterController: controller
        )
    }

    private func setupNotifications() {
        NotificationCenter.default.addObserver(
            forName: .startCapture,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                await self?.startCapture()
            }
        }

        NotificationCenter.default.addObserver(
            forName: .stopCapture,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                await self?.stopCapture()
            }
        }
    }

    func startCapture() async {
        guard !appState.isCapturing else { return }

        if !PermissionManager.shared.hasScreenRecordingPermission {
            let granted = await PermissionManager.shared.requestScreenRecordingPermission()
            if !granted {
                appState.setError("Screen recording permission is required")
                return
            }
        }

        guard let overlay = overlayManager else {
            appState.setError("Overlay not initialized")
            return
        }

        if #available(macOS 12.3, *) {
            await matchCaptureResolutionToWindow()
            captureManager = ScreenCaptureManager(settings: captureSettings)

            do {
                let stream = try await captureManager!.startCapture()
                appState.startCapture()
                resetPerCaptureState()

                if #available(macOS 14.0, *) {
                    interpolator = nil
                }

                if #available(macOS 26.0, *) {
                    appleVSRProcessor?.updateTargetResolution(
                        resolvedAppleVSRTargetResolution()
                    )
                }

                createDisplayForCapture(overlay: overlay)

                captureTask = Task { [weak self] in
                    do {
                        for try await frame in stream {
                            await self?.processFrame(frame)
                        }
                    } catch {
                        await MainActor.run {
                            self?.appState.setError(
                                "Capture stream error: \(error.localizedDescription)"
                            )
                        }
                        await self?.stopCapture()
                    }
                }
            } catch {
                appState.setError(
                    "Failed to start capture: \(error.localizedDescription)"
                )
            }
        } else {
            appState.setError("ScreenCaptureKit requires macOS 12.3 or later")
        }
    }

    func stopCapture() async {
        guard appState.isCapturing else { return }

        appState.stopCapture()

        let task = captureTask
        captureTask = nil
        task?.cancel()

        if #available(macOS 12.3, *) {
            await captureManager?.stopCapture()
            captureManager = nil
        }

        if #available(macOS 14.0, *) {
            await interpolator?.stop()
            interpolator = nil
        }

        if #available(macOS 26.0, *) {
            appleVSRProcessor?.stop()
        }

        overlayManager?.close()
        resetPerCaptureState()
    }

    private func resetPerCaptureState() {
        frameCount = 0
        interpolatedFrameCount = 0
        passthroughFrameCount = 0
        sourceFrameCount = 0
        currentSourceFPS = 0
        lastFrameTimestamp = nil
        currentProcessingResolution = nil
        hasConfiguredContentRatio = false
        lastFPSTime = Date()
    }

    private func processFrame(_ frame: CapturedFrame) async {
        guard let overlay = overlayManager else { return }
        sourceFrameCount += 1

        let currentPTS = frame.presentationTimestamp
        let previousPTS = lastFrameTimestamp ?? currentPTS
        lastFrameTimestamp = currentPTS

        configureContentRatioIfNeeded(frame: frame, overlay: overlay)

        if upscaleSettings.frameInterpolationEnabled,
           #available(macOS 14.0, *)
        {
            let handled = await processWithInterpolation(
                frame: frame,
                previousPTS: previousPTS,
                overlay: overlay
            )

            if handled {
                return
            }
        }

        await displaySingleFrame(
            frame.pixelBuffer,
            overlay: overlay,
            interpolationStatus: nil
        )
    }

    private func configureContentRatioIfNeeded(
        frame: CapturedFrame,
        overlay: OverlayManager
    ) {
        guard !hasConfiguredContentRatio else { return }

        let bufferWidth = CGFloat(CVPixelBufferGetWidth(frame.pixelBuffer))
        let contentWidth = frame.contentRect.width * frame.scaleFactor

        if bufferWidth > 0,
           contentWidth > 0,
           contentWidth < bufferWidth
        {
            let ratio = contentWidth / bufferWidth
            overlay.setContentWidthRatio(ratio)
            print(
                "   📐 Content width ratio: "
                    + String(format: "%.3f", ratio)
                    + " (\(Int(contentWidth))/\(Int(bufferWidth)) px)"
            )
        }

        hasConfiguredContentRatio = true
    }

    @available(macOS 14.0, *)
    private func processWithInterpolation(
        frame: CapturedFrame,
        previousPTS: CMTime,
        overlay: OverlayManager
    ) async -> Bool {
        do {
            if interpolator == nil {
                let width = Int32(CVPixelBufferGetWidth(frame.pixelBuffer))
                let height = Int32(CVPixelBufferGetHeight(frame.pixelBuffer))
                let dimensions = CMVideoDimensions(width: width, height: height)
                let betweenCount = max(
                    1,
                    min(3, upscaleSettings.interpolationMultiplier - 1)
                )
                let processing = upscaleSettings.processingResolution.dimensions

                interpolator = try RealTimeFrameInterpolation(
                    numFrames: betweenCount,
                    inputDimensions: dimensions,
                    maxWidth: processing.width,
                    maxHeight: processing.height,
                    spatialUpscale: upscaleSettings.spatialUpscaleEnabled
                )
                try await interpolator?.start()
            }

            guard let outputs = try await interpolator?.process(
                currentBuffer: frame.pixelBuffer,
                currentTimestamp: frame.presentationTimestamp
            ) else {
                return false
            }

            let modelReady = await interpolator?.modelReady ?? false

            if modelReady {
                interpolatedFrameCount += outputs.count
                passthroughFrameCount = 0

                let allFrames = outputs + [frame.pixelBuffer]
                var processedFrames: [CVPixelBuffer] = []
                processedFrames.reserveCapacity(allFrames.count)

                var lastVSRStatus: String?
                for buffer in allFrames {
                    let processed = await applyAppleVSRIfEnabled(buffer)
                    processedFrames.append(processed.pixelBuffer)
                    currentProcessingResolution = processed.outputSize
                    lastVSRStatus = processed.vsrStatus
                }

                let totalPerInput = processedFrames.count
                let frameDuration = max(
                    0,
                    CMTimeGetSeconds(frame.presentationTimestamp)
                        - CMTimeGetSeconds(previousPTS)
                )
                let step = totalPerInput > 0
                    ? frameDuration / Double(totalPerInput)
                    : 0

                for (index, buffer) in processedFrames.enumerated() {
                    overlay.enqueueBuffer(
                        buffer,
                        offsetFromNow: step * Double(index)
                    )
                    updateFPS()
                }

                let interpolationText =
                    "Interpolation \(upscaleSettings.interpolationMultiplier)x"
                appState.processingStatus = combinedStatus(
                    interpolation: interpolationText,
                    vsr: lastVSRStatus
                )
                return true
            }

            if await interpolator?.modelFailed ?? false {
                let current = upscaleSettings.processingResolution

                if let lower = current.lowerResolution {
                    upscaleSettings.processingResolution = lower
                    await interpolator?.stop()
                    interpolator = nil

                    await displaySingleFrame(
                        frame.pixelBuffer,
                        overlay: overlay,
                        interpolationStatus:
                            "Interpolation \(current.rawValue) unsupported; retrying at \(lower.rawValue)"
                    )
                } else {
                    await displaySingleFrame(
                        frame.pixelBuffer,
                        overlay: overlay,
                        interpolationStatus: "Interpolation unsupported on this device"
                    )
                }

                return true
            }

            passthroughFrameCount += 1
            await displaySingleFrame(
                frame.pixelBuffer,
                overlay: overlay,
                interpolationStatus:
                    "Loading interpolation model (\(upscaleSettings.processingResolution.rawValue))"
            )
            return true
        } catch {
            await displaySingleFrame(
                frame.pixelBuffer,
                overlay: overlay,
                interpolationStatus:
                    "Interpolation failed: \(error.localizedDescription)"
            )
            return true
        }
    }

    private func displaySingleFrame(
        _ pixelBuffer: CVPixelBuffer,
        overlay: OverlayManager,
        interpolationStatus: String?
    ) async {
        let processed = await applyAppleVSRIfEnabled(pixelBuffer)
        currentProcessingResolution = processed.outputSize
        appState.processingStatus = combinedStatus(
            interpolation: interpolationStatus,
            vsr: processed.vsrStatus
        )
        overlay.displayBufferImmediate(processed.pixelBuffer)
        updateFPS()
    }

    private func applyAppleVSRIfEnabled(
        _ pixelBuffer: CVPixelBuffer
    ) async -> (
        pixelBuffer: CVPixelBuffer,
        outputSize: CGSize,
        vsrStatus: String?
    ) {
        let inputSize = CGSize(
            width: CVPixelBufferGetWidth(pixelBuffer),
            height: CVPixelBufferGetHeight(pixelBuffer)
        )

        guard upscaleSettings.superResolutionEnabled else {
            return (pixelBuffer, inputSize, nil)
        }

        guard #available(macOS 26.0, *),
              let appleVSRProcessor
        else {
            return (
                pixelBuffer,
                inputSize,
                "Apple VSR requires macOS 26"
            )
        }

        appleVSRProcessor.updateTargetResolution(
            resolvedAppleVSRTargetResolution()
        )

        let result = await appleVSRProcessor.process(pixelBuffer: pixelBuffer)
        return (
            result.pixelBuffer,
            result.outputSize,
            result.status
        )
    }

    private func combinedStatus(
        interpolation: String?,
        vsr: String?
    ) -> String {
        switch (interpolation, vsr) {
        case let (interpolation?, vsr?):
            return "\(interpolation) + \(vsr)"
        case let (interpolation?, nil):
            return interpolation
        case let (nil, vsr?):
            return vsr
        case (nil, nil):
            return "Passthrough"
        }
    }

    private func updateFPS() {
        frameCount += 1
        let now = Date()
        let elapsed = now.timeIntervalSince(lastFPSTime)

        if elapsed >= 1.0 {
            let fps = Double(frameCount) / elapsed
            currentSourceFPS = Double(sourceFrameCount) / elapsed
            appState.updateFPS(fps)

            frameCount = 0
            sourceFrameCount = 0
            lastFPSTime = now

            var processingResolution = currentProcessingResolution

            if processingResolution == nil,
               #available(macOS 14.0, *),
               let interpolator
            {
                let dimensions = interpolator.outputDimensions
                processingResolution = CGSize(
                    width: CGFloat(dimensions.width),
                    height: CGFloat(dimensions.height)
                )
            }

            overlayManager?.updateDebugInfo(
                fps: fps,
                sourceFPS: currentSourceFPS,
                status: appState.processingStatus,
                captureRes: captureSettings.captureResolution,
                processingRes: processingResolution,
                mode: processingModeLabel
            )
        }
    }

    var processingModeLabel: String {
        switch (
            upscaleSettings.superResolutionEnabled,
            upscaleSettings.frameInterpolationEnabled
        ) {
        case (true, true):
            return "Apple VSR + Frame Interpolation"
        case (true, false):
            return "Apple VSR"
        case (false, true):
            return "Frame Interpolation"
        case (false, false):
            return "Passthrough"
        }
    }

    private func matchCaptureResolutionToWindow() async {
        // No-op: window ID may map to auxiliary windows with tiny dimensions.
        // Default 1920x1080 is reliable.
    }

    private func createDisplayForCapture(overlay: OverlayManager) {
        if let windowID = captureSettings.targetWindowID {
            overlay.createOverlayOnWindow(windowID: windowID)
            overlay.show()
            print("   🎯 Overlay mode: tracking window \(windowID)")
        } else {
            let captureSize = captureSettings.captureResolution
            overlay.createDisplayWindow(contentSize: captureSize)
            overlay.show()
            print("   🖥️ Standalone window mode")
        }
    }

    func setDebugOverlay(_ visible: Bool) {
        overlayManager?.showDebugOverlay = visible
    }

    func updateUpscaleSettings(_ newSettings: UpscaleSettings) {
        upscaleSettings = newSettings

        if #available(macOS 26.0, *) {
            if newSettings.superResolutionEnabled {
                appleVSRProcessor?.updateTargetResolution(
                    resolvedAppleVSRTargetResolution()
                )
            } else {
                appleVSRProcessor?.stop()
            }
        }
    }

    func setAppleVSREnabled(_ enabled: Bool) {
        upscaleSettings.superResolutionEnabled = enabled

        if #available(macOS 26.0, *) {
            if enabled {
                appleVSRProcessor?.updateTargetResolution(
                    resolvedAppleVSRTargetResolution()
                )
            } else {
                appleVSRProcessor?.stop()
            }
        }
    }

    func setFrameInterpolationEnabled(_ enabled: Bool) {
        upscaleSettings.frameInterpolationEnabled = enabled

        guard !enabled else { return }

        if #available(macOS 14.0, *) {
            let activeInterpolator = interpolator
            interpolator = nil
            Task {
                await activeInterpolator?.stop()
            }
        }
    }

    func resetFrameInterpolator() {
        if #available(macOS 14.0, *) {
            let activeInterpolator = interpolator
            interpolator = nil
            Task {
                await activeInterpolator?.stop()
            }
        }
    }

    func setAppleVSRTargetMode(_ mode: AppleVSRTargetMode) {
        appleVSRTargetMode = mode
        upscaleSettings.targetResolution = resolvedAppleVSRTargetResolution()

        if #available(macOS 26.0, *) {
            appleVSRProcessor?.updateTargetResolution(
                resolvedAppleVSRTargetResolution()
            )
        }
    }

    func resolvedAppleVSRTargetResolution() -> CGSize {
        if let fixedResolution = appleVSRTargetMode.fixedResolution {
            return fixedResolution
        }

        guard let screen = NSScreen.main ?? NSScreen.screens.first else {
            return CGSize(width: 2560, height: 1440)
        }

        let scale = screen.backingScaleFactor
        let nativeWidth = max(
            1,
            Int((screen.frame.width * scale).rounded())
        )
        let nativeHeight = max(
            1,
            Int((screen.frame.height * scale).rounded())
        )

        if nativeWidth > 3840 {
            let ratio = Double(nativeHeight) / Double(nativeWidth)
            return CGSize(
                width: 3840,
                height: Int((3840.0 * ratio).rounded())
            )
        }

        return CGSize(width: nativeWidth, height: nativeHeight)
    }

    // MARK: - Picker

    @available(macOS 12.3, *)
    func presentPicker() {
        if captureManager == nil {
            captureManager = ScreenCaptureManager(settings: captureSettings)
            captureManager?.onPickerFilterSelected = { [weak self] filter in
                Task { @MainActor in
                    await self?.startCaptureWithFilter(filter)
                }
            }
        }
        captureManager?.presentPicker()
    }

    @available(macOS 12.3, *)
    private func startCaptureWithFilter(_ filter: SCContentFilter) async {
        guard !appState.isCapturing else { return }
        guard let overlay = overlayManager else { return }

        do {
            let stream = try await captureManager!.startCapture()
            await captureManager?.applyPickerFilter(filter)
            appState.startCapture()
            resetPerCaptureState()

            if #available(macOS 14.0, *) {
                interpolator = nil
            }

            if #available(macOS 26.0, *) {
                appleVSRProcessor?.updateTargetResolution(
                    resolvedAppleVSRTargetResolution()
                )
            }

            createDisplayForCapture(overlay: overlay)

            captureTask = Task { [weak self] in
                do {
                    for try await frame in stream {
                        await self?.processFrame(frame)
                    }
                } catch {
                    await MainActor.run {
                        self?.appState.setError(
                            "Capture stream error: \(error.localizedDescription)"
                        )
                    }
                    await self?.stopCapture()
                }
            }
        } catch {
            appState.setError(
                "Failed to start capture: \(error.localizedDescription)"
            )
        }
    }
}
