import Foundation

/// Memory sticks are FAT32 or exFAT, which can't store a file's extended
/// attributes, so macOS keeps them in a hidden companion named "._<name>".
/// macOS attaches such an attribute to every file written by an app that was
/// downloaded from the internet, and the PSP lists the companion of a video as
/// a corrupted video.
///
/// The App Sandbox forbids deleting these companions, which is why this app
/// isn't sandboxed.
enum AppleDouble {
    /// Every AppleDouble file starts with these four bytes.
    private static let magic: [UInt8] = [0x00, 0x05, 0x16, 0x07]

    /// Deletes the "._" companion of `file`, if there is one and it really is an
    /// AppleDouble file. Volumes that store attributes natively have none.
    static func removeCompanion(of file: URL) {
        let companion = file.deletingLastPathComponent().appendingPathComponent("._" + file.lastPathComponent)
        guard let handle = try? FileHandle(forReadingFrom: companion) else { return }
        let header = (try? handle.read(upToCount: magic.count)) ?? Data()
        try? handle.close()
        guard Array(header) == magic else { return }
        try? FileManager.default.removeItem(at: companion)
    }
}
