import AppKit
import Observation
import UniformTypeIdentifiers

struct QueueItem: Identifiable {
    enum Status: Equatable {
        case waiting
        case converting(Double)
        case finished(URL)
        case failed(String)
    }

    let id = UUID()
    let source: SourceInfo
    var status: Status = .waiting
    /// Frames the PSP thumbnail can be made from; empty until they've been read from the video.
    var thumbnails: [CGImage] = []
    /// Index into `thumbnails`, or nil when the video should get no thumbnail.
    var selectedThumbnail: Int? = 0

    var thumbnail: CGImage? {
        guard let selectedThumbnail, thumbnails.indices.contains(selectedThumbnail) else { return nil }
        return thumbnails[selectedThumbnail]
    }
}

@MainActor
@Observable
final class ConversionModel {
    /// What the file picker offers. Whether a file is really usable is decided by
    /// trying to open it, so this only needs to be broad.
    static let pickableTypes: [UTType] = [.movie, .video, .folder]
        + otherVideoExtensions.compactMap { UTType(filenameExtension: $0) }
    /// Video formats macOS may not classify as movies, so folders are searched for them by name.
    private static let otherVideoExtensions: Set<String> = [
        "mkv", "webm", "wmv", "asf", "flv", "f4v", "ogv", "ogm", "divx", "rm", "rmvb", "mxf", "vob", "ts", "m2ts", "mts",
    ]

    private(set) var items: [QueueItem] = []
    private(set) var isConverting = false
    /// A one-line message about files that couldn't be added.
    private(set) var notice: String?
    var quality: Quality = .standard
    var scaling: Scaling = .fit
    /// Where converted videos are saved; nil until the user picks a folder,
    /// which they're asked to do the first time they convert.
    private(set) var outputFolder: URL?

    private var task: Task<Void, Never>?

    init() {
        FFmpegHelper.removeLeftovers()
    }

    /// Items the next "Convert" will process: waiting ones plus failed ones, which are retried.
    var pending: [QueueItem] {
        items.filter {
            switch $0.status {
            case .waiting, .failed: true
            case .converting, .finished: false
            }
        }
    }

    var finishedCount: Int {
        items.count { if case .finished = $0.status { true } else { false } }
    }

    func estimatedSize(of items: [QueueItem]) -> String {
        let bytes = items.reduce(Int64(0)) { $0 + PSPConverter.estimatedBytes(for: $1.source, quality: quality) }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    /// Adds videos to the queue. Files added mid-batch are picked up by the running batch.
    ///
    /// Videos macOS can decode are read directly; anything else (MKV, WebM, DivX…)
    /// goes through the bundled FFmpeg. Folders are searched for videos, including subfolders.
    func add(_ urls: [URL]) {
        Task {
            var skipped = 0
            for url in Self.expandingFolders(urls) {
                guard let source = await Self.inspect(url) else {
                    skipped += 1
                    continue
                }
                if !items.contains(where: { $0.source.url == url }) {
                    let item = QueueItem(source: source)
                    items.append(item)
                    loadThumbnails(for: item)
                }
            }
            notice = switch skipped {
            case 0: nil
            case 1: "Skipped 1 file that isn't a readable video."
            default: "Skipped \(skipped) files that aren't readable videos."
            }
        }
    }

    private static func inspect(_ url: URL) async -> SourceInfo? {
        if let source = try? await PSPConverter.inspect(url) { return source }
        return try? await FFmpegHelper.inspect(url)
    }

    /// Replaces each folder with the video files inside it. Files given directly
    /// are kept whatever their type, so unreadable ones get reported as skipped.
    private static func expandingFolders(_ urls: [URL]) -> [URL] {
        var result: [URL] = []
        for url in urls.map(\.standardizedFileURL) {
            guard (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else {
                result.append(url)
                continue
            }
            let enumerator = FileManager.default.enumerator(
                at: url, includingPropertiesForKeys: [.contentTypeKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            )
            var found: [URL] = []
            while let file = enumerator?.nextObject() as? URL {
                guard let type = (try? file.resourceValues(forKeys: [.contentTypeKey]))?.contentType,
                      type.conforms(to: .movie) || type.conforms(to: .video)
                        || Self.otherVideoExtensions.contains(file.pathExtension.lowercased()) else { continue }
                // Don't pick up this app's own output when a folder is added again.
                if file.deletingPathExtension().lastPathComponent.hasSuffix("(PSP)") { continue }
                found.append(file.standardizedFileURL)
            }
            result += found.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        }
        return result
    }

    private func loadThumbnails(for item: QueueItem) {
        Task {
            let (images, best) = await PSPThumbnail.candidates(for: item.source)
            guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }
            items[index].thumbnails = images
            if items[index].selectedThumbnail != nil { items[index].selectedThumbnail = best }
        }
    }

    /// Chooses which frame becomes the thumbnail, or nil for none. For a video
    /// that's already converted, its thumbnail file is updated straight away.
    func selectThumbnail(_ selection: Int?, for item: QueueItem) {
        guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        if let selection, !items[index].thumbnails.indices.contains(selection) { return }
        items[index].selectedThumbnail = selection
        guard case .finished(let url) = items[index].status else { return }
        if let image = items[index].thumbnail {
            try? PSPThumbnail.write(image, for: url)
        } else {
            try? FileManager.default.removeItem(at: PSPThumbnail.url(for: url))
        }
    }

    /// Asks where to save `image` as a standalone thumbnail file. The suggested
    /// name matches the converted video's, so it works on the PSP as-is.
    func exportThumbnail(_ image: CGImage, for item: QueueItem) {
        let panel = NSSavePanel()
        panel.title = "Export Thumbnail"
        let folder = outputFolder ?? item.source.url.deletingLastPathComponent()
        panel.directoryURL = folder
        panel.nameFieldStringValue = PSPThumbnail.url(
            for: Self.destination(for: item.source.url, in: folder, unique: false)
        ).lastPathComponent
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try PSPThumbnail.write(image, to: url)
        } catch {
            notice = "The thumbnail couldn't be saved to \(url.lastPathComponent)."
        }
    }

    /// Saves the chosen frame beside a converted video. A missing thumbnail only
    /// means a generic icon on the PSP, so failures here are ignored.
    private func writeThumbnail(for id: QueueItem.ID, video: URL) async {
        guard let item = items.first(where: { $0.id == id }), item.selectedThumbnail != nil else { return }
        if let chosen = item.thumbnail {
            try? PSPThumbnail.write(chosen, for: video)
        } else {
            // The previews hadn't loaded yet; take the best frame from the converted file.
            let (images, best) = await PSPThumbnail.candidates(for: video)
            if images.indices.contains(best) { try? PSPThumbnail.write(images[best], for: video) }
        }
    }

    func remove(_ item: QueueItem) {
        if case .converting = item.status { return }
        items.removeAll { $0.id == item.id }
    }

    func clear() {
        guard !isConverting else { return }
        items.removeAll()
        notice = nil
    }

    /// Asks where converted videos should go. Returns false if the user cancels.
    @discardableResult
    func chooseOutputFolder() -> Bool {
        let panel = NSOpenPanel()
        panel.title = "Save Converted Videos To"
        panel.message = "Choose the folder to save converted videos in."
        panel.prompt = "Choose"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.directoryURL = outputFolder ?? pending.first?.source.url.deletingLastPathComponent()
        guard panel.runModal() == .OK, let url = panel.url else { return false }
        outputFolder = url
        return true
    }

    func convertAll() {
        guard !isConverting, !pending.isEmpty else { return }
        guard outputFolder != nil || chooseOutputFolder(), let outputFolder else { return }
        for index in items.indices {
            if case .failed = items[index].status { items[index].status = .waiting }
        }
        guard items.contains(where: { $0.status == .waiting }) else { return }
        isConverting = true
        notice = nil
        let quality = quality, scaling = scaling

        task = Task {
            defer { isConverting = false }
            while !Task.isCancelled, let item = items.first(where: { $0.status == .waiting }) {
                let id = item.id
                let destination = Self.destination(for: item.source.url, in: outputFolder)
                setStatus(.converting(0), for: id)
                do {
                    try await convert(item.source, to: destination, quality: quality, scaling: scaling) { fraction in
                        Task { @MainActor [weak self] in self?.reportProgress(fraction, for: id) }
                    }
                    await writeThumbnail(for: id, video: destination)
                    setStatus(.finished(destination), for: id)
                } catch is CancellationError {
                    setStatus(.waiting, for: id)
                } catch {
                    setStatus(.failed(error.localizedDescription), for: id)
                }
            }
        }
    }

    /// Converts one video. A file only FFmpeg can read is first prepared into a
    /// temporary movie, which takes the first part of the progress bar.
    private nonisolated func convert(
        _ source: SourceInfo,
        to destination: URL,
        quality: Quality,
        scaling: Scaling,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        var input = source.url
        var intermediate: URL?
        defer { if let intermediate { try? FileManager.default.removeItem(at: intermediate) } }

        let share = FFmpegHelper.preparationShare(for: source)
        if source.reader != .native {
            let prepared = try await FFmpegHelper.prepare(source) { progress($0 * share) }
            intermediate = prepared
            input = prepared
        }
        try await PSPConverter.convert(source: input, destination: destination, quality: quality, scaling: scaling) {
            progress(share + $0 * (1 - share))
        }
    }

    /// Stops the batch. The video in progress goes back to waiting; finished ones are kept.
    func cancel() {
        task?.cancel()
    }

    func reveal(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private func setStatus(_ status: QueueItem.Status, for id: QueueItem.ID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].status = status
    }

    private func reportProgress(_ fraction: Double, for id: QueueItem.ID) {
        // Progress callbacks can arrive after the item has already finished.
        guard let index = items.firstIndex(where: { $0.id == id }),
              case .converting = items[index].status else { return }
        items[index].status = .converting(fraction)
    }

    /// "<name> (PSP).mp4" in `folder`, numbered if that already exists.
    private static func destination(for source: URL, in folder: URL, unique: Bool = true) -> URL {
        let name = source.deletingPathExtension().lastPathComponent
        var candidate = folder.appendingPathComponent("\(name) (PSP).mp4")
        var counter = 2
        while unique, FileManager.default.fileExists(atPath: candidate.path) {
            candidate = folder.appendingPathComponent("\(name) (PSP) \(counter).mp4")
            counter += 1
        }
        return candidate
    }
}
