import AVFoundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// The thumbnail the PSP shows for a video in its list: a 160x120 JPEG with the
/// video's name and a ".THM" extension, in the same folder.
enum PSPThumbnail {
    static let size = CGSize(width: 160, height: 120)
    /// Positions in the video offered as thumbnails, as fractions of its length.
    private static let candidatePositions = [0.08, 0.2, 0.35, 0.5, 0.65, 0.8]

    static func url(for video: URL) -> URL {
        video.deletingPathExtension().appendingPathExtension("THM")
    }

    /// Frames from across `video`, each cropped to the thumbnail's 4:3 shape,
    /// plus the index of the most detailed one (so not a black or blank frame).
    static func candidates(for source: SourceInfo) async -> (images: [CGImage], best: Int) {
        switch source.reader {
        case .native:
            return await candidates(for: source.url)
        case .ffmpeg:
            return await candidates(duration: source.duration) { seconds in
                await FFmpegHelper.frame(of: source.url, at: seconds)
            }
        }
    }

    /// The same, for a video macOS can read directly.
    static func candidates(for video: URL) async -> (images: [CGImage], best: Int) {
        let asset = AVURLAsset(url: video)
        guard let duration = try? await asset.load(.duration).seconds, duration > 0 else { return ([], 0) }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 640, height: 480)
        // Any nearby frame will do, which lets the generator use keyframes and stay fast.
        generator.requestedTimeToleranceBefore = CMTime(seconds: 5, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 5, preferredTimescale: 600)

        return await candidates(duration: duration) { seconds in
            try? await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600)).image
        }
    }

    private static func candidates(
        duration: Double,
        frameAt: (Double) async -> CGImage?
    ) async -> (images: [CGImage], best: Int) {
        var images: [CGImage] = []
        var best = 0
        var bestDetail = -1.0
        for position in candidatePositions {
            guard let frame = await frameAt(duration * position),
                  let thumbnail = cropped(frame) else { continue }
            let detail = detail(of: thumbnail)
            if detail > bestDetail {
                bestDetail = detail
                best = images.count
            }
            images.append(thumbnail)
        }
        return (images, best)
    }

    /// Saves `image` as the thumbnail for `video`.
    static func write(_ image: CGImage, for video: URL) throws {
        try write(image, to: url(for: video))
    }

    /// Saves `image` as a JPEG at `destination`, whatever its extension.
    static func write(_ image: CGImage, to destination: URL) throws {
        guard let writer = CGImageDestinationCreateWithURL(
            destination as CFURL, UTType.jpeg.identifier as CFString, 1, nil
        ) else { throw ConversionError.cannotWrite }
        CGImageDestinationAddImage(writer, image, [
            kCGImageDestinationLossyCompressionQuality: 0.85,
        ] as CFDictionary)
        guard CGImageDestinationFinalize(writer) else { throw ConversionError.cannotWrite }
    }

    /// Scales `frame` to fill 160x120, trimming the sides of widescreen video.
    private static func cropped(_ frame: CGImage) -> CGImage? {
        guard let context = CGContext(
            data: nil, width: Int(size.width), height: Int(size.height),
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return nil }
        let scale = max(size.width / CGFloat(frame.width), size.height / CGFloat(frame.height))
        let scaled = CGSize(width: CGFloat(frame.width) * scale, height: CGFloat(frame.height) * scale)
        context.interpolationQuality = .high
        context.draw(frame, in: CGRect(
            x: (size.width - scaled.width) / 2, y: (size.height - scaled.height) / 2,
            width: scaled.width, height: scaled.height
        ))
        return context.makeImage()
    }

    /// Spread of brightness across the image; near zero for black or flat frames.
    private static func detail(of image: CGImage) -> Double {
        guard let data = image.dataProvider?.data, let bytes = CFDataGetBytePtr(data) else { return 0 }
        var sum = 0.0, sumOfSquares = 0.0, count = 0.0
        for row in 0..<image.height {
            for column in 0..<image.width {
                let pixel = bytes + row * image.bytesPerRow + column * 4
                let luma = 0.299 * Double(pixel[0]) + 0.587 * Double(pixel[1]) + 0.114 * Double(pixel[2])
                sum += luma
                sumOfSquares += luma * luma
                count += 1
            }
        }
        guard count > 0 else { return 0 }
        let mean = sum / count
        return sumOfSquares / count - mean * mean
    }
}
