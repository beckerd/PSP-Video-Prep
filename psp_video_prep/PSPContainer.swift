import Foundation

/// Turns the plain MP4 that AVAssetWriter produces into the PSP flavour of MP4
/// ("MSNV"), matching what ffmpeg's `-f psp` muxer writes:
///
/// - an `ftyp` box with the Sony `MSNV` brand,
/// - a `uuid`/`PROF` box right after it describing both streams,
/// - a `uuid`/`USMT` box in every track,
/// - and none of the optional boxes Apple adds that the PSP has no use for.
///
/// The audio and video data are copied byte-for-byte; only the header and the
/// index (`moov`) are rewritten.
struct PSPContainer {
    struct Profile {
        var width: Int
        var height: Int
        var framesPerSecond: Double
        var videoBitRate: Int
        /// nil when the movie has no audio track.
        var audio: (bitRate: Int, sampleRate: Int, channels: Int)?
    }

    enum Failure: LocalizedError {
        case unexpectedLayout
        var errorDescription: String? { "The encoded file couldn't be packaged for the PSP." }
    }

    private static let containers: Set<String> = ["moov", "trak", "mdia", "minf", "stbl"]
    /// Sample-dependency flags, sample groups (AAC pre-roll) and user metadata.
    private static let dropped: Set<String> = ["sdtp", "sgpd", "sbgp", "udta", "meta"]
    /// Bytes of fixed fields in a video sample entry before its child boxes.
    private static let videoSampleEntryHeader = 86
    /// The UUID Sony uses for its PROF and USMT boxes (after the 4-char type).
    private static let sonyUUID: [UInt32] = [0x21d2_4fce, 0xbb88_695c, 0xfac9_c740]

    /// How far the media data moves when the header is replaced; chunk offsets shift by this.
    private let offsetDelta: Int64

    static func package(fileAt url: URL, profile: Profile) throws {
        let input = try FileHandle(forReadingFrom: url)
        defer { try? input.close() }
        let fileSize = try input.seekToEnd()

        // Expect: ftyp first, moov last, and exactly one mdat in between.
        var ftypSize: UInt64?
        var moovOffset: UInt64?
        var media: (payloadOffset: UInt64, payloadSize: UInt64)?
        var mediaCount = 0
        var offset: UInt64 = 0
        while offset + 8 <= fileSize {
            try input.seek(toOffset: offset)
            guard let header = try input.read(upToCount: 16), header.count >= 8 else { break }
            var size = UInt64(header.uint32(at: 0))
            var headerSize: UInt64 = 8
            if size == 1, header.count == 16 { size = header.uint64(at: 8); headerSize = 16 }
            if size == 0 { size = fileSize - offset }
            guard size >= headerSize, offset + size <= fileSize else { throw Failure.unexpectedLayout }
            switch header.type(at: 4) {
            case "ftyp" where offset == 0: ftypSize = size
            case "moov" where offset + size == fileSize: moovOffset = offset
            case "mdat":
                media = (offset + headerSize, size - headerSize)
                mediaCount += 1
            default: break
            }
            offset += size
        }
        // The PSP is limited to FAT32 files, so the media must fit a 32-bit box size.
        guard ftypSize != nil, let moovOffset, let media, mediaCount == 1,
              media.payloadOffset + media.payloadSize <= moovOffset,
              media.payloadSize + 8 <= UInt64(UInt32.max),
              fileSize - moovOffset < 512 * 1024 * 1024 else { throw Failure.unexpectedLayout }

        try input.seek(toOffset: moovOffset)
        guard let moov = try input.read(upToCount: Int(fileSize - moovOffset)),
              moov.count == Int(fileSize - moovOffset) else { throw Failure.unexpectedLayout }

        // New layout: ftyp, PROF, mdat (plain 32-bit header), moov. AVAssetWriter
        // writes mdat with a 64-bit size field, which a real PSP (firmware 6.61)
        // rejects as "Corrupted Data"; with the 32-bit header the same streams play.
        var header = fileTypeBox() + profileBox(profile)
        header.appendUInt32(UInt32(media.payloadSize + 8))
        header.appendType("mdat")
        let container = PSPContainer(offsetDelta: Int64(header.count) - Int64(media.payloadOffset))
        let newMoov = container.filter(box: moov)

        let temporary = url.appendingPathExtension("packaging")
        FileManager.default.createFile(atPath: temporary.path, contents: nil)
        do {
            let output = try FileHandle(forWritingTo: temporary)
            defer { try? output.close() }
            try output.write(contentsOf: header)
            try input.seek(toOffset: media.payloadOffset)
            var remaining = media.payloadSize
            while remaining > 0 {
                let count = Int(min(remaining, 8 * 1024 * 1024))
                guard let chunk = try input.read(upToCount: count), !chunk.isEmpty else { throw Failure.unexpectedLayout }
                try output.write(contentsOf: chunk)
                remaining -= UInt64(chunk.count)
            }
            try output.write(contentsOf: newMoov)
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
        // A plain remove-and-rename within the same folder; unlike replaceItemAt it
        // needs no access beyond the output folder, which matters in the sandbox.
        do {
            try FileManager.default.removeItem(at: url)
            try FileManager.default.moveItem(at: temporary, to: url)
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
    }

    // MARK: Sony boxes

    private static func fileTypeBox() -> Data {
        var body = Data()
        body.appendType("MSNV")
        body.appendUInt32(0x200)
        for brand in ["MSNV", "isom", "iso2", "avc1"] { body.appendType(brand) }
        return box("ftyp", body)
    }

    /// Stream summary the PSP reads before anything else. Video must be track 1, audio track 2.
    private static func profileBox(_ profile: Profile) -> Data {
        let audioKbps = (profile.audio?.bitRate ?? 0) / 1000
        // Sony's format caps the declared total at 800 kbps; ffmpeg clamps the same way.
        let videoKbps = UInt32(max(min(profile.videoBitRate / 1000, 800 - audioKbps), 1))
        let frameRate = UInt32((profile.framesPerSecond * 65536).rounded())

        var sections = [box("FPRF", words: [0, 0, 0])]
        if let audio = profile.audio {
            var aprf = Data()
            aprf.appendUInt32(0)
            aprf.appendUInt32(2) // track ID
            aprf.appendType("mp4a")
            for word in [0x20f, 0, UInt32(audioKbps), UInt32(audioKbps), UInt32(audio.sampleRate), UInt32(audio.channels)] {
                aprf.appendUInt32(word)
            }
            sections.append(box("APRF", aprf))
        }
        var vprf = Data()
        vprf.appendUInt32(0)
        vprf.appendUInt32(1) // track ID
        vprf.appendType("avc1")
        vprf.appendUInt32(0x014D_0015)
        for word in [0, videoKbps, videoKbps, frameRate, frameRate] { vprf.appendUInt32(word) }
        vprf.appendUInt32(UInt32(profile.width) << 16 | UInt32(profile.height))
        vprf.appendUInt32(0x0001_0001)
        sections.append(box("VPRF", vprf))

        var body = Data()
        body.appendType("PROF")
        sonyUUID.forEach { body.appendUInt32($0) }
        body.appendUInt32(0)
        body.appendUInt32(UInt32(sections.count))
        sections.forEach { body.append($0) }
        return box("uuid", body)
    }

    /// Fixed per-track box; ffmpeg's source notes it is "critical for PSP playback".
    private static func trackBox() -> Data {
        var body = Data()
        body.appendType("USMT")
        sonyUUID.forEach { body.appendUInt32($0) }
        body.append(box("MTDT", words: [0x0001_0012, 0x0a, 0x55c4_0000, 0x1, 0x0]))
        return box("uuid", body)
    }

    private static func box(_ type: String, _ body: Data) -> Data {
        var result = Data()
        result.appendUInt32(UInt32(body.count + 8))
        result.appendType(type)
        result.append(body)
        return result
    }

    private static func box(_ type: String, words: [UInt32]) -> Data {
        var body = Data()
        words.forEach { body.appendUInt32($0) }
        return box(type, body)
    }

    // MARK: Index rewriting

    /// Returns `box` (header included) cleaned up and adjusted for the new header size.
    private func filter(box: Data) -> Data {
        let type = box.type(at: 4)
        if Self.containers.contains(type) { return rebuiltContainer(box) }
        switch type {
        case "stsd": return filteredSampleDescriptions(box)
        case "tkhd": return trackHeaderMarkedInMovie(box)
        case "stco": return shiftedChunkOffsets(box, entrySize: 4)
        case "co64": return shiftedChunkOffsets(box, entrySize: 8)
        default: return box
        }
    }

    private func rebuiltContainer(_ container: Data) -> Data {
        let isTrack = container.type(at: 4) == "trak"
        var body = Data()
        var offset = 8
        while offset + 8 <= container.count {
            let size = Int(container.uint32(at: offset))
            guard size >= 8, offset + size <= container.count else { break }
            let child = container.subdata(in: offset..<offset + size)
            let childType = child.type(at: 4)
            if !Self.dropped.contains(childType) {
                body.append(filter(box: child))
                if isTrack, childType == "mdia" { body.append(Self.trackBox()) }
            }
            offset += size
        }
        // Anything that didn't parse as a box is kept untouched.
        if offset < container.count { body.append(container.subdata(in: offset..<container.count)) }
        return Self.box(type(of: container), body)
    }

    private func type(of box: Data) -> String { box.type(at: 4) }

    /// AVAssetWriter flags tracks as "enabled" only. Players that follow the spec
    /// strictly skip tracks without "in movie" set, so set enabled + in movie (0x3)
    /// as ffmpeg does.
    private func trackHeaderMarkedInMovie(_ tkhd: Data) -> Data {
        guard tkhd.count >= 12 else { return tkhd }
        var result = tkhd
        result[result.startIndex + 11] |= 0x03
        return result
    }

    private func shiftedChunkOffsets(_ table: Data, entrySize: Int) -> Data {
        guard table.count >= 16 else { return table }
        let count = Int(table.uint32(at: 12))
        guard table.count >= 16 + count * entrySize else { return table }
        var result = table.subdata(in: 0..<16)
        for index in 0..<count {
            let position = 16 + index * entrySize
            if entrySize == 4 {
                result.appendUInt32(UInt32(Int64(table.uint32(at: position)) + offsetDelta))
            } else {
                let value = UInt64(Int64(table.uint64(at: position)) + offsetDelta)
                result.appendUInt32(UInt32(value >> 32))
                result.appendUInt32(UInt32(value & 0xffff_ffff))
            }
        }
        result.append(table.subdata(in: 16 + count * entrySize..<table.count))
        return result
    }

    /// In H.264 sample entries keeps only the decoder configuration ("avcC"),
    /// dropping the colour, field and chroma-location extensions.
    private func filteredSampleDescriptions(_ stsd: Data) -> Data {
        guard stsd.count >= 16 else { return stsd }
        let header = Self.videoSampleEntryHeader
        var body = stsd.subdata(in: 8..<16) // version/flags + entry count
        var offset = 16
        while offset + 8 <= stsd.count {
            let size = Int(stsd.uint32(at: offset))
            guard size >= 8, offset + size <= stsd.count else { return stsd }
            let entry = stsd.subdata(in: offset..<offset + size)
            if entry.type(at: 4) == "avc1", entry.count > header {
                var kept = Data()
                var child = header
                while child + 8 <= entry.count {
                    let childSize = Int(entry.uint32(at: child))
                    guard childSize >= 8, child + childSize <= entry.count else { return stsd }
                    if entry.type(at: child + 4) == "avcC" { kept.append(entry.subdata(in: child..<child + childSize)) }
                    child += childSize
                }
                guard !kept.isEmpty else { return stsd }
                body.append(Self.box("avc1", entry.subdata(in: 8..<header) + kept))
            } else {
                body.append(entry)
            }
            offset += size
        }
        return Self.box("stsd", body)
    }
}

private extension Data {
    func uint32(at offset: Int) -> UInt32 {
        subdata(in: offset..<offset + 4).reduce(0) { $0 << 8 | UInt32($1) }
    }

    func uint64(at offset: Int) -> UInt64 {
        subdata(in: offset..<offset + 8).reduce(0) { $0 << 8 | UInt64($1) }
    }

    func type(at offset: Int) -> String {
        String(decoding: subdata(in: offset..<offset + 4), as: UTF8.self)
    }

    mutating func appendUInt32(_ value: UInt32) {
        append(contentsOf: [UInt8(value >> 24), UInt8(value >> 16 & 0xff), UInt8(value >> 8 & 0xff), UInt8(value & 0xff)])
    }

    mutating func appendType(_ type: String) {
        append(contentsOf: Array(type.utf8))
    }
}
