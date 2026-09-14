//
//  AppleVSRProcessor.swift
//  MetalDuck
//
//  Low-latency Apple VideoToolbox super-resolution pipeline.
//

import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
@preconcurrency import VideoToolbox

@available(macOS 26.0, *)
@MainActor
final class AppleVSRProcessor {
    struct Output {
        let pixelBuffer: CVPixelBuffer
        let usedSuperResolution: Bool
        let outputSize: CGSize
        let scaleFactor: Float?
        let status: String
    }

    private struct ConfigurationKey: Equatable {
        let captureWidth: Int
        let captureHeight: Int
        let targetWidth: Int
        let targetHeight: Int
    }

    private struct PreparedConfiguration {
        let configuration: VTLowLatencySuperResolutionScalerConfiguration
        let sourcePool: CVPixelBufferPool
        let destinationPool: CVPixelBufferPool
        let modelWidth: Int
        let modelHeight: Int
        let scaleFactor: Float
    }

    private var targetResolution: CGSize
    private var processor: VTFrameProcessor?
    private var configuration: VTLowLatencySuperResolutionScalerConfiguration?
    private var sourcePool: CVPixelBufferPool?
    private var destinationPool: CVPixelBufferPool?
    private var transferSession: VTPixelTransferSession?
    private var configurationKey: ConfigurationKey?
    private var sessionStarted = false
    private var modelInputSize: CGSize?
    private var selectedScaleFactor: Float?
    private var frameCounter: Int64 = 0

    init(targetResolution: CGSize) {
        self.targetResolution = targetResolution
        setupTransferSession()
    }

    deinit {
        processor?.endSession()
        if let transferSession {
            VTPixelTransferSessionInvalidate(transferSession)
        }
    }

    static var isSupported: Bool {
        VTLowLatencySuperResolutionScalerConfiguration.isSupported
    }

    func updateTargetResolution(_ resolution: CGSize) {
        guard resolution.width > 0, resolution.height > 0 else { return }
        guard resolution != targetResolution else { return }
        targetResolution = resolution
        resetSession()
    }

    func stop() {
        resetSession()
    }

    func process(pixelBuffer: CVPixelBuffer) async -> Output {
        let captureWidth = CVPixelBufferGetWidth(pixelBuffer)
        let captureHeight = CVPixelBufferGetHeight(pixelBuffer)
        let captureSize = CGSize(width: captureWidth, height: captureHeight)

        guard Self.isSupported else {
            return passthrough(
                pixelBuffer,
                size: captureSize,
                status: "Apple VSR unsupported on this Mac"
            )
        }

        let key = ConfigurationKey(
            captureWidth: captureWidth,
            captureHeight: captureHeight,
            targetWidth: max(1, Int(targetResolution.width.rounded())),
            targetHeight: max(1, Int(targetResolution.height.rounded()))
        )

        if configurationKey != key {
            resetSession()

            guard let prepared = Self.makeConfiguration(for: key) else {
                return passthrough(
                    pixelBuffer,
                    size: captureSize,
                    status: "No Apple VSR model size is supported for \(captureWidth)×\(captureHeight)"
                )
            }

            configuration = prepared.configuration
            sourcePool = prepared.sourcePool
            destinationPool = prepared.destinationPool
            modelInputSize = CGSize(
                width: prepared.modelWidth,
                height: prepared.modelHeight
            )
            selectedScaleFactor = prepared.scaleFactor
            processor = VTFrameProcessor()
            configurationKey = key
        }

        guard let processor,
              let configuration,
              let sourcePool,
              let destinationPool
        else {
            return passthrough(
                pixelBuffer,
                size: captureSize,
                status: "Apple VSR is not configured"
            )
        }

        if !sessionStarted {
            do {
                try processor.startSession(configuration: configuration)
                sessionStarted = true
            } catch {
                let reason = "Apple VSR model failed to load: \(error.localizedDescription)"
                resetSession()
                return passthrough(pixelBuffer, size: captureSize, status: reason)
            }
        }

        guard let modelInput = makeBuffer(from: sourcePool) else {
            return passthrough(
                pixelBuffer,
                size: captureSize,
                status: "Apple VSR could not allocate its input surface"
            )
        }

        guard transfer(pixelBuffer, to: modelInput) else {
            return passthrough(
                pixelBuffer,
                size: captureSize,
                status: "Apple VSR could not convert the captured frame"
            )
        }

        guard let destination = makeBuffer(from: destinationPool) else {
            return passthrough(
                pixelBuffer,
                size: captureSize,
                status: "Apple VSR could not allocate its output surface"
            )
        }

        pixelBuffer.propagateAttachments(to: destination)

        frameCounter &+= 1
        let timestamp = CMTime(value: frameCounter, timescale: 600)

        guard let sourceFrame = VTFrameProcessorFrame(
            buffer: modelInput,
            presentationTimeStamp: timestamp
        ),
        let destinationFrame = VTFrameProcessorFrame(
            buffer: destination,
            presentationTimeStamp: timestamp
        ) else {
            return passthrough(
                pixelBuffer,
                size: captureSize,
                status: "Apple VSR rejected its frame surfaces"
            )
        }

        let parameters = VTLowLatencySuperResolutionScalerParameters(
            sourceFrame: sourceFrame,
            destinationFrame: destinationFrame
        )

        do {
            try await processor.process(parameters: parameters)
            pixelBuffer.propagateAttachments(to: destination)

            let outputWidth = CVPixelBufferGetWidth(destination)
            let outputHeight = CVPixelBufferGetHeight(destination)
            let factor = selectedScaleFactor ?? 1.0
            let modelSize = modelInputSize ?? captureSize

            return Output(
                pixelBuffer: destination,
                usedSuperResolution: true,
                outputSize: CGSize(width: outputWidth, height: outputHeight),
                scaleFactor: factor,
                status: String(
                    format: "Apple VSR %.1fx (%dx%d → %dx%d)",
                    factor,
                    Int(modelSize.width),
                    Int(modelSize.height),
                    outputWidth,
                    outputHeight
                )
            )
        } catch {
            return passthrough(
                pixelBuffer,
                size: captureSize,
                status: "Apple VSR processing failed: \(error.localizedDescription)"
            )
        }
    }

    private func setupTransferSession() {
        var session: VTPixelTransferSession?
        guard VTPixelTransferSessionCreate(
            allocator: kCFAllocatorDefault,
            pixelTransferSessionOut: &session
        ) == noErr else {
            return
        }
        transferSession = session
    }

    private func transfer(
        _ source: CVPixelBuffer,
        to destination: CVPixelBuffer
    ) -> Bool {
        if transferSession == nil {
            setupTransferSession()
        }

        guard let transferSession else { return false }

        return VTPixelTransferSessionTransferImage(
            transferSession,
            from: source,
            to: destination
        ) == noErr
    }

    private func makeBuffer(from pool: CVPixelBufferPool) -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferPoolCreatePixelBuffer(
            kCFAllocatorDefault,
            pool,
            &buffer
        )
        return status == kCVReturnSuccess ? buffer : nil
    }

    private func passthrough(
        _ pixelBuffer: CVPixelBuffer,
        size: CGSize,
        status: String
    ) -> Output {
        Output(
            pixelBuffer: pixelBuffer,
            usedSuperResolution: false,
            outputSize: size,
            scaleFactor: selectedScaleFactor,
            status: status
        )
    }

    private func resetSession() {
        if sessionStarted {
            processor?.endSession()
        }

        processor = nil
        configuration = nil
        sourcePool = nil
        destinationPool = nil
        configurationKey = nil
        sessionStarted = false
        modelInputSize = nil
        selectedScaleFactor = nil
        frameCounter = 0
    }

    private static func makeConfiguration(
        for key: ConfigurationKey
    ) -> PreparedConfiguration? {
        let candidates = candidateInputSizes(
            captureWidth: key.captureWidth,
            captureHeight: key.captureHeight
        )

        for candidate in candidates {
            let factors = VTLowLatencySuperResolutionScalerConfiguration
                .supportedScaleFactors(
                    frameWidth: candidate.width,
                    frameHeight: candidate.height
                )
                .filter { $0 > 1.0 }
                .sorted()

            guard !factors.isEmpty else { continue }

            let desiredScale = max(
                1.0,
                min(
                    Float(key.targetWidth) / Float(candidate.width),
                    Float(key.targetHeight) / Float(candidate.height)
                )
            )

            let factor = factors.first(where: { $0 >= desiredScale })
                ?? factors.last!

            let configuration = VTLowLatencySuperResolutionScalerConfiguration(
                frameWidth: candidate.width,
                frameHeight: candidate.height,
                scaleFactor: factor
            )

            guard let sourcePool = createPool(
                attributes: configuration.sourcePixelBufferAttributes,
                width: candidate.width,
                height: candidate.height
            ) else {
                continue
            }

            let outputWidth = Int(
                (Double(candidate.width) * Double(factor)).rounded()
            )
            let outputHeight = Int(
                (Double(candidate.height) * Double(factor)).rounded()
            )

            guard let destinationPool = createPool(
                attributes: configuration.destinationPixelBufferAttributes,
                width: outputWidth,
                height: outputHeight
            ) else {
                continue
            }

            return PreparedConfiguration(
                configuration: configuration,
                sourcePool: sourcePool,
                destinationPool: destinationPool,
                modelWidth: candidate.width,
                modelHeight: candidate.height,
                scaleFactor: factor
            )
        }

        return nil
    }

    private static func candidateInputSizes(
        captureWidth: Int,
        captureHeight: Int
    ) -> [(width: Int, height: Int)] {
        var candidates: [(width: Int, height: Int)] = []

        func appendUnique(width: Int, height: Int) {
            guard width > 0, height > 0 else { return }

            let evenWidth = max(2, width - (width % 2))
            let evenHeight = max(2, height - (height % 2))

            guard evenWidth <= captureWidth,
                  evenHeight <= captureHeight
            else {
                return
            }

            if let minimum = VTLowLatencySuperResolutionScalerConfiguration.minimumDimensions,
               Int32(evenWidth) < minimum.width || Int32(evenHeight) < minimum.height
            {
                return
            }

            if let maximum = VTLowLatencySuperResolutionScalerConfiguration.maximumDimensions,
               Int32(evenWidth) > maximum.width || Int32(evenHeight) > maximum.height
            {
                return
            }

            guard !candidates.contains(where: {
                $0.width == evenWidth && $0.height == evenHeight
            }) else {
                return
            }

            candidates.append((evenWidth, evenHeight))
        }

        appendUnique(width: captureWidth, height: captureHeight)

        if let maximum = VTLowLatencySuperResolutionScalerConfiguration.maximumDimensions {
            let scale = min(
                1.0,
                min(
                    Double(maximum.width) / Double(captureWidth),
                    Double(maximum.height) / Double(captureHeight)
                )
            )

            appendUnique(
                width: Int((Double(captureWidth) * scale).rounded(.down)),
                height: Int((Double(captureHeight) * scale).rounded(.down))
            )
        }

        for maxWidth in [1920, 1600, 1440, 1280, 960, 854, 640] {
            guard maxWidth < captureWidth else { continue }
            let scale = Double(maxWidth) / Double(captureWidth)
            appendUnique(
                width: maxWidth,
                height: Int((Double(captureHeight) * scale).rounded(.down))
            )
        }

        return candidates.sorted {
            ($0.width * $0.height) > ($1.width * $1.height)
        }
    }

    private static func createPool(
        attributes: [String: Any],
        width: Int,
        height: Int
    ) -> CVPixelBufferPool? {
        var resolved = attributes
        resolved[kCVPixelBufferWidthKey as String] = width
        resolved[kCVPixelBufferHeightKey as String] = height
        resolved[kCVPixelBufferMetalCompatibilityKey as String] = true

        if resolved[kCVPixelBufferIOSurfacePropertiesKey as String] == nil {
            resolved[kCVPixelBufferIOSurfacePropertiesKey as String] = [String: Any]()
        }

        let poolAttributes: [String: Any] = [
            kCVPixelBufferPoolMinimumBufferCountKey as String: 3
        ]

        var pool: CVPixelBufferPool?
        let status = CVPixelBufferPoolCreate(
            kCFAllocatorDefault,
            poolAttributes as CFDictionary,
            resolved as CFDictionary,
            &pool
        )

        return status == kCVReturnSuccess ? pool : nil
    }
}
