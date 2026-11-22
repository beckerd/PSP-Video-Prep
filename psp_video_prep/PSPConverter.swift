import AVFoundation
import CoreGraphics

/// Video bitrate presets. Standard keeps video + audio under the 768 kbps that
/// Sony documents for the PSP; High and Maximum go beyond it for a sharper picture.
/// Standard and High have been confirmed playing on a real PSP (firmware 6.61).
enum Quality: String, CaseIterable, Identifiable {
    case standard, high, maximum

    var id: Self { self }

    var label: String {
        switch self {
        case .standard: "Standard (smallest files)"
        case .high: "High"
        case .maximum: "Maximum (best picture)"
        }
    }

    var videoBitRate: Int {
        switch self {
        case .standard: 640_000
        case .high: 1_500_000
        case .maximum: 2_500_000
        }
    }

    var audioBitRate: Int { self == .standard ? 96_000 : 128_000 }
}

/// How a source that isn't 480:272 is placed on the PSP screen.
enum Scaling: String, CaseIterable, Identifiable {
    case fit, fill, stretch

    var id: Self { self }

    var label: String {
        switch self {
        case .fit: "Fit (black bars)"
        case .fill: "Fill (crop edges)"
        case .stretch: "Stretch"
        }
    }
}

struct SourceInfo: Equatable {
    let url: URL
    let duration: Double
    let displaySize: CGSize
    let frameRate: Double
    let hasAudio: Bool
    var reader: Reader = .native

    /// What can open this file.
    enum Reader: Equatable {
        /// macOS reads it directly.
        case native
        /// Only the bundled FFmpeg can; it has to be prepared into a temporary movie first.
        case ffmpeg(videoCodec: String)
    }
}

enum ConversionError: LocalizedError {
    case noVideoTrack
    case cannotRead
    case cannotWrite

    var errorDescription: String? {
        switch self {
        case .noVideoTrack: "This file doesn't contain a video track."
        case .cannotRead: "The video couldn't be read. It may be DRM-protected or use an unsupported codec."
        case .cannotWrite: "The PSP video couldn't be written."
        }
    }
}

enum PSPConverter {
    /// The PSP's native screen resolution.
    static let screenSize = CGSize(width: 480, height: 272)
    static let maxFrameRate = 30.0
    static let audioSampleRate = 48_000.0

    static func inspect(_ url: URL) async throws -> SourceInfo {
        let asset = AVURLAsset(url: url)
        guard let video = try await asset.loadTracks(withMediaType: .video).first else {
            throw ConversionError.noVideoTrack
        }
        // A container macOS can open may still hold a codec it can't decode (e.g. DivX in AVI).
        guard try await video.load(.isDecodable) else { throw ConversionError.cannotRead }
        let (naturalSize, transform, fps) = try await video.load(.naturalSize, .preferredTransform, .nominalFrameRate)
        let oriented = CGRect(origin: .zero, size: naturalSize).applying(transform)
        return SourceInfo(
            url: url,
            duration: try await asset.load(.duration).seconds,
            displaySize: CGSize(width: abs(oriented.width), height: abs(oriented.height)),
            frameRate: Double(fps),
            hasAudio: try await !asset.loadTracks(withMediaType: .audio).isEmpty
        )
    }

    static func estimatedBytes(for source: SourceInfo, quality: Quality) -> Int64 {
        let bitsPerSecond = quality.videoBitRate + (source.hasAudio ? quality.audioBitRate : 0)
        return Int64(source.duration * Double(bitsPerSecond) / 8)
    }

    /// Transcodes `source` into a PSP-playable MP4 at `destination`:
    /// 480x272 H.264 Main@3.0 (no B-frames), at most 30 fps, AAC-LC stereo 48 kHz.
    static func convert(
        source: URL,
        destination: URL,
        quality: Quality,
        scaling: Scaling,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        let asset = AVURLAsset(url: source)
        let duration = try await asset.load(.duration)
        guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else {
            throw ConversionError.noVideoTrack
        }
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        let (naturalSize, preferredTransform, nominalFrameRate) =
            try await videoTrack.load(.naturalSize, .preferredTransform, .nominalFrameRate)

        let frameDuration = frameDuration(forSourceFrameRate: Double(nominalFrameRate))
        let frameRate = 1 / frameDuration.seconds
        let videoBitRate = quality.videoBitRate

        // MARK: Reader

        let reader = try AVAssetReader(asset: asset)

        let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: videoTrack)
        layer.setTransform(
            placement(naturalSize: naturalSize, preferredTransform: preferredTransform, scaling: scaling),
            at: .zero
        )
        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: duration)
        instruction.layerInstructions = [layer]

        let composition = AVMutableVideoComposition()
        composition.renderSize = screenSize
        composition.frameDuration = frameDuration
        composition.instructions = [instruction]
        // Converts everything (HD and HDR sources included) to standard-definition
        // colour. The PSP ignores colour tags and always decodes as BT.601, so
        // encoding HD-style BT.709 would shift the colours on its screen.
        composition.colorPrimaries = AVVideoColorPrimaries_SMPTE_C
        composition.colorTransferFunction = AVVideoTransferFunction_ITU_R_709_2
        composition.colorYCbCrMatrix = AVVideoYCbCrMatrix_ITU_R_601_4

        let videoOutput = AVAssetReaderVideoCompositionOutput(
            videoTracks: [videoTrack],
            videoSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange]
        )
        videoOutput.videoComposition = composition
        videoOutput.alwaysCopiesSampleData = false
        guard reader.canAdd(videoOutput) else { throw ConversionError.cannotRead }
        reader.add(videoOutput)

        var audioOutput: AVAssetReaderAudioMixOutput?
        if !audioTracks.isEmpty {
            let output = AVAssetReaderAudioMixOutput(audioTracks: audioTracks, audioSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: audioSampleRate,
                AVNumberOfChannelsKey: 2,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false,
            ])
            output.alwaysCopiesSampleData = false
            if reader.canAdd(output) {
                reader.add(output)
                audioOutput = output
            }
        }

        // MARK: Writer

        let writer = try AVAssetWriter(outputURL: destination, fileType: .mp4)
        // The index is left at the end of the file, where PSPContainer expects it.
        writer.shouldOptimizeForNetworkUse = false
        writer.movieTimeScale = 1000

        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(screenSize.width),
            AVVideoHeightKey: Int(screenSize.height),
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_SMPTE_C,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_601_4,
            ],
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: videoBitRate,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264Main30,
                AVVideoH264EntropyModeKey: AVVideoH264EntropyModeCABAC,
                // B-frames measured slightly worse at the same bitrate with this encoder.
                AVVideoAllowFrameReorderingKey: false,
                AVVideoExpectedSourceFrameRateKey: Int(frameRate.rounded()),
                AVVideoMaxKeyFrameIntervalDurationKey: 2,
            ] as [String: Any],
        ])
        videoInput.expectsMediaDataInRealTime = false
        // Without this the writer uses a 600 timescale, which can't represent
        // 23.976/29.97 fps exactly and yields uneven frame durations the PSP rejects.
        videoInput.mediaTimeScale = frameDuration.timescale
        guard writer.canAdd(videoInput) else { throw ConversionError.cannotWrite }
        writer.add(videoInput)

        var audioInput: AVAssetWriterInput?
        if audioOutput != nil {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: audioSampleRate,
                AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: quality.audioBitRate,
            ])
            input.expectsMediaDataInRealTime = false
            guard writer.canAdd(input) else { throw ConversionError.cannotWrite }
            writer.add(input)
            audioInput = input
        }

        // MARK: Transcode

        guard reader.startReading() else { throw reader.error ?? ConversionError.cannotRead }
        guard writer.startWriting() else { throw writer.error ?? ConversionError.cannotWrite }
        writer.startSession(atSourceTime: .zero)

        let totalSeconds = max(duration.seconds, 0.001)
        async let videoDone: Void = pump(videoOutput, into: videoInput, writer: writer, frameDuration: frameDuration) { time in
            progress(min(max(time.seconds / totalSeconds, 0), 1))
        }
        if let audioOutput, let audioInput {
            await pump(audioOutput, into: audioInput, writer: writer)
        }
        await videoDone

        if Task.isCancelled || reader.status == .failed || writer.status == .failed {
            let failure = reader.error ?? writer.error
            reader.cancelReading()
            writer.cancelWriting()
            removePartialOutput(at: destination)
            if Task.isCancelled { throw CancellationError() }
            throw failure ?? ConversionError.cannotWrite
        }

        await writer.finishWriting()
        guard writer.status == .completed else {
            try? FileManager.default.removeItem(at: destination)
            throw writer.error ?? ConversionError.cannotWrite
        }
        do {
            try PSPContainer.package(fileAt: destination, profile: PSPContainer.Profile(
                width: Int(screenSize.width),
                height: Int(screenSize.height),
                framesPerSecond: frameRate,
                videoBitRate: videoBitRate,
                audio: audioInput == nil ? nil : (quality.audioBitRate, Int(audioSampleRate), 2)
            ))
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
        progress(1)
    }

    /// Deletes an abandoned output file, plus the "<name>.sb-…" scratch files
    /// AVAssetWriter can leave beside it when writing is cancelled.
    private static func removePartialOutput(at destination: URL) {
        let fileManager = FileManager.default
        try? fileManager.removeItem(at: destination)
        let folder = destination.deletingLastPathComponent()
        let prefix = destination.lastPathComponent + ".sb-"
        for name in (try? fileManager.contentsOfDirectory(atPath: folder.path)) ?? [] where name.hasPrefix(prefix) {
            try? fileManager.removeItem(at: folder.appendingPathComponent(name))
        }
    }

    /// The constant frame duration to encode at. Standard rates are kept exactly
    /// (60/50 fps are halved so motion stays even); anything else becomes 29.97.
    static func frameDuration(forSourceFrameRate sourceFrameRate: Double) -> CMTime {
        var rate = sourceFrameRate
        while rate > maxFrameRate + 0.01 { rate /= 2 }
        let standard: [(rate: Double, duration: CMTime)] = [
            (15 / 1.001, CMTime(value: 1001, timescale: 15000)),
            (15, CMTime(value: 1000, timescale: 15000)),
            (24 / 1.001, CMTime(value: 1001, timescale: 24000)),
            (24, CMTime(value: 1000, timescale: 24000)),
            (25, CMTime(value: 1000, timescale: 25000)),
            (30 / 1.001, CMTime(value: 1001, timescale: 30000)),
            (30, CMTime(value: 1000, timescale: 30000)),
        ]
        return standard.first { abs($0.rate - rate) < 0.011 }?.duration
            ?? CMTime(value: 1001, timescale: 30000)
    }

    /// Moves samples from a reader output to a writer input until the source is
    /// exhausted, the writer fails, or the task is cancelled.
    ///
    /// Video passes `frameDuration` to get a strictly constant frame rate: each
    /// frame is snapped to the nearest multiple of `frameDuration`, and a slot the
    /// source skipped is filled by repeating the previous frame, so the output
    /// never drifts from the audio and every frame has the same length.
    private static func pump(
        _ output: AVAssetReaderOutput,
        into input: AVAssetWriterInput,
        writer: AVAssetWriter,
        frameDuration: CMTime? = nil,
        onProgress: ((CMTime) -> Void)? = nil
    ) async {
        func append(_ sample: CMSampleBuffer) async -> Bool {
            while writer.status == .writing, !Task.isCancelled {
                if input.isReadyForMoreMediaData { return input.append(sample) }
                try? await Task.sleep(for: .milliseconds(2))
            }
            return false
        }

        var lastReported = CMTime.zero
        var nextSlot: Int64 = 0
        var previous: CMSampleBuffer?

        reading: while writer.status == .writing, !Task.isCancelled {
            guard let sample = output.copyNextSampleBuffer() else { break }
            let time = sample.presentationTimeStamp
            guard sample.numSamples > 0, time.isNumeric else { continue }

            if let frameDuration {
                var slot = Int64((time.seconds / frameDuration.seconds).rounded())
                if slot < nextSlot - 1 { continue } // more than a frame late: drop it
                slot = max(slot, nextSlot)
                while nextSlot < slot, let previous {
                    guard await append(retimed(previous, slot: nextSlot, frameDuration: frameDuration)) else { break reading }
                    nextSlot += 1
                }
                guard await append(retimed(sample, slot: slot, frameDuration: frameDuration)) else { break }
                nextSlot = slot + 1
                previous = sample
            } else {
                guard await append(sample) else { break }
            }

            // Report at most twice per second of video.
            if let onProgress, (time - lastReported).seconds >= 0.5 {
                lastReported = time
                onProgress(time)
            }
        }
        if writer.status == .writing { input.markAsFinished() }
    }

    /// A copy of `sample` presented at `slot × frameDuration` for exactly one frame.
    private static func retimed(_ sample: CMSampleBuffer, slot: Int64, frameDuration: CMTime) -> CMSampleBuffer {
        var timing = CMSampleTimingInfo(
            duration: frameDuration,
            presentationTimeStamp: CMTime(value: slot * frameDuration.value, timescale: frameDuration.timescale),
            decodeTimeStamp: .invalid
        )
        var copy: CMSampleBuffer?
        CMSampleBufferCreateCopyWithNewTiming(
            allocator: nil, sampleBuffer: sample,
            sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleBufferOut: &copy
        )
        return copy ?? sample
    }

    /// Transform that takes the track's raw frames to their upright orientation
    /// and then places them on the 480x272 canvas.
    private static func placement(
        naturalSize: CGSize,
        preferredTransform: CGAffineTransform,
        scaling: Scaling
    ) -> CGAffineTransform {
        let oriented = CGRect(origin: .zero, size: naturalSize).applying(preferredTransform)
        guard oriented.width > 0, oriented.height > 0 else { return preferredTransform }

        var scaleX = screenSize.width / oriented.width
        var scaleY = screenSize.height / oriented.height
        switch scaling {
        case .fit: scaleX = min(scaleX, scaleY); scaleY = scaleX
        case .fill: scaleX = max(scaleX, scaleY); scaleY = scaleX
        case .stretch: break
        }

        return preferredTransform
            .concatenating(CGAffineTransform(translationX: -oriented.minX, y: -oriented.minY))
            .concatenating(CGAffineTransform(scaleX: scaleX, y: scaleY))
            .concatenating(CGAffineTransform(
                translationX: (screenSize.width - oriented.width * scaleX) / 2,
                y: (screenSize.height - oriented.height * scaleY) / 2
            ))
    }
}
