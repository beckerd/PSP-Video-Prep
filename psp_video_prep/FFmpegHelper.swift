import CoreGraphics
import Foundation
import ImageIO

/// Runs the FFmpeg program bundled with the app to read formats macOS can't
/// open by itself (MKV, WebM, AVI/DivX, WMV, FLV…).
///
/// FFmpeg is only used to get such a file into a form the rest of the app can
/// read: `prepare` writes a temporary QuickTime movie, which then goes through
/// the same PSP conversion as any other video. FFmpeg runs as a separate
/// process; none of its code is linked into the app (see Helpers/FFMPEG-NOTICE.txt).
enum FFmpegHelper {
    /// Video codecs macOS decodes natively, so the stream can be copied as-is
    /// instead of being re-encoded for the intermediate file.
    private static let copyableVideoCodecs: Set<String> = ["h264", "hevc"]
    /// Width cap for re-encoded intermediates: twice the PSP's screen, so the
    /// final downscale still has detail to work with.
    private static let intermediateMaxWidth = 960

    /// The bundled program, or nil if the app was built without it
    /// (run scripts/build-ffmpeg.sh to produce it).
    static let executable: URL? = {
        let candidates = [
            Bundle.main.url(forAuxiliaryExecutable: "ffmpeg"),
            Bundle.main.url(forResource: "ffmpeg", withExtension: nil),
        ]
        return candidates.compactMap { $0 }.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }()

    static var isAvailable: Bool { executable != nil }

    // MARK: Inspecting

    /// Reads a video's basic properties from FFmpeg's description of the file.
    static func inspect(_ url: URL) async throws -> SourceInfo {
        // With no output file FFmpeg prints what it found and exits with an error; that's expected.
        let result = try await run(["-hide_banner", "-nostdin", "-i", url.path])
        guard let info = parse(description: result.stderr, url: url) else { throw ConversionError.cannotRead }
        return info
    }

    /// Parses lines such as
    /// `Duration: 01:33:23.92, start: 0.000000, bitrate: 1234 kb/s` and
    /// `Stream #0:0(eng): Video: h264 (High), yuv420p, 1280x720 [SAR 1:1 DAR 16:9], 23.98 fps, …`.
    static func parse(description: String, url: URL) -> SourceInfo? {
        var duration: Double?
        var video: (codec: String, size: CGSize, frameRate: Double)?
        var hasAudio = false

        for line in description.split(whereSeparator: \.isNewline).map(String.init) {
            if duration == nil, let match = line.firstMatch(of: /Duration: (\d+):(\d+):(\d+(?:\.\d+)?)/) {
                duration = Double(match.1)! * 3600 + Double(match.2)! * 60 + Double(match.3)!
            } else if line.contains("Stream #"), line.contains("Audio:") {
                hasAudio = true
            } else if video == nil, line.contains("Stream #"), line.contains("Video:"),
                      !line.contains("attached pic"),
                      let codec = line.firstMatch(of: /Video: ([A-Za-z0-9_]+)/),
                      let size = line.firstMatch(of: /, (\d{2,5})x(\d{2,5})/) {
                var width = Double(size.1)!
                let height = Double(size.2)!
                // Anamorphic video: use the shape it's displayed at, not the stored pixels.
                if let shape = line.firstMatch(of: /DAR (\d+):(\d+)/), Double(shape.2)! > 0 {
                    width = (height * Double(shape.1)! / Double(shape.2)!).rounded()
                }
                let rate = line.firstMatch(of: /([\d.]+) fps/) ?? line.firstMatch(of: /([\d.]+) tbr/)
                video = (String(codec.1), CGSize(width: width, height: height), rate.flatMap { Double($0.1) } ?? 0)
            }
        }
        guard let duration, duration > 0, let video else { return nil }
        return SourceInfo(
            url: url,
            duration: duration,
            displaySize: video.size,
            frameRate: video.frameRate,
            hasAudio: hasAudio,
            reader: .ffmpeg(videoCodec: video.codec)
        )
    }

    // MARK: Preparing

    /// How much of a conversion's time goes into `prepare` for this source:
    /// copying a stream is quick, re-encoding one is about half the work.
    static func preparationShare(for source: SourceInfo) -> Double {
        guard case .ffmpeg(let codec) = source.reader else { return 0 }
        return copyableVideoCodecs.contains(codec) ? 0.1 : 0.5
    }

    /// Writes a temporary QuickTime movie macOS can read and returns its
    /// location; the caller deletes it. The video is copied untouched when macOS
    /// can decode it, and otherwise re-encoded at a bitrate far above anything
    /// the PSP version will use. Audio always becomes uncompressed stereo.
    static func prepare(_ source: SourceInfo, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        guard case .ffmpeg(let codec) = source.reader else { return source.url }
        let output = try temporaryFolder().appendingPathComponent(UUID().uuidString + ".mov")

        var arguments = ["-hide_banner", "-nostdin", "-y", "-i", source.url.path,
                         "-map", "0:v:0", "-map", "0:a:0?", "-sn", "-dn"]
        if copyableVideoCodecs.contains(codec) {
            arguments += ["-c:v", "copy"]
            if codec == "hevc" { arguments += ["-tag:v", "hvc1"] }
        } else {
            let width = "trunc(min(\(intermediateMaxWidth),iw*sar)/2)*2"
            let height = "trunc(min(\(intermediateMaxWidth),iw*sar)/dar/2)*2"
            arguments += ["-vf", "scale=w='\(width)':h='\(height)',setsar=1,format=yuv420p",
                          "-c:v", "h264_videotoolbox", "-allow_sw", "1", "-b:v", "8M"]
        }
        arguments += ["-c:a", "pcm_s16le", "-ac", "2", "-ar", "48000",
                      "-progress", "pipe:1", "-nostats", "-f", "mov", output.path]

        let duration = max(source.duration, 0.001)
        do {
            let result = try await run(arguments) { chunk in
                // "-progress" writes key=value lines; out_time_us is the position reached.
                for line in String(decoding: chunk, as: UTF8.self).split(whereSeparator: \.isNewline) {
                    if let match = line.firstMatch(of: /^out_time_us=(\d+)/), let microseconds = Double(match.1) {
                        progress(min(max(microseconds / 1_000_000 / duration, 0), 1))
                    }
                }
            }
            try Task.checkCancellation()
            guard result.status == 0 else { throw ConversionError.cannotRead }
            return output
        } catch {
            try? FileManager.default.removeItem(at: output)
            throw error
        }
    }

    /// Removes intermediates left behind by an earlier run that didn't finish cleanly.
    static func removeLeftovers() {
        if let folder = try? temporaryFolder() { try? FileManager.default.removeItem(at: folder) }
    }

    private static func temporaryFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("PSP Video Prep", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    // MARK: Frames

    /// A single frame near `seconds`, at most 640 pixels wide with square pixels.
    static func frame(of url: URL, at seconds: Double) async -> CGImage? {
        let arguments = ["-hide_banner", "-nostdin", "-ss", String(format: "%.3f", seconds), "-i", url.path,
                         "-map", "0:v:0", "-frames:v", "1",
                         "-vf", "scale=w='trunc(min(640,iw*sar)/2)*2':h='trunc(min(640,iw*sar)/dar/2)*2',setsar=1",
                         "-f", "image2pipe", "-c:v", "mjpeg", "-q:v", "3", "-"]
        guard let result = try? await run(arguments), result.status == 0,
              let source = CGImageSourceCreateWithData(result.stdout as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    // MARK: Running

    private final class Collector: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()

        func append(_ chunk: Data) {
            lock.lock()
            data.append(chunk)
            lock.unlock()
        }

        var value: Data {
            lock.lock()
            defer { lock.unlock() }
            return data
        }
    }

    /// Runs FFmpeg to completion, collecting what it prints. Cancelling the
    /// task stops the process.
    private static func run(
        _ arguments: [String],
        onStandardOutput: (@Sendable (Data) -> Void)? = nil
    ) async throws -> (status: Int32, stdout: Data, stderr: String) {
        guard let executable else { throw ConversionError.cannotRead }
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        let outputPipe = Pipe(), errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        let output = Collector(), errors = Collector()
        let readers = DispatchGroup()
        func collect(_ handle: FileHandle, into collector: Collector, each: (@Sendable (Data) -> Void)?) {
            readers.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                while true {
                    let chunk = handle.availableData
                    if chunk.isEmpty { break }
                    collector.append(chunk)
                    each?(chunk)
                }
                readers.leave()
            }
        }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                // The group is balanced by the process exiting and by each pipe reaching
                // end-of-file. (Process.waitUntilExit can hang off the main thread.)
                readers.enter()
                process.terminationHandler = { _ in readers.leave() }
                do {
                    try process.run()
                } catch {
                    process.terminationHandler = nil
                    continuation.resume(throwing: error)
                    return
                }
                // Our copies of the write ends must be closed, or the readers never see end-of-file.
                try? outputPipe.fileHandleForWriting.close()
                try? errorPipe.fileHandleForWriting.close()
                collect(outputPipe.fileHandleForReading, into: output, each: onStandardOutput)
                collect(errorPipe.fileHandleForReading, into: errors, each: nil)
                readers.notify(queue: .global(qos: .userInitiated)) {
                    continuation.resume(returning: (
                        process.terminationStatus,
                        output.value,
                        String(decoding: errors.value, as: UTF8.self)
                    ))
                }
            }
        } onCancel: {
            if process.isRunning { process.terminate() }
        }
    }
}
