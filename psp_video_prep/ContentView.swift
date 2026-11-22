import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @State private var model = ConversionModel()
    @State private var isDropTargeted = false
    @State private var isChoosingFiles = false

    var body: some View {
        VStack(spacing: 0) {
            if model.items.isEmpty {
                emptyState
            } else {
                List(model.items) { item in
                    QueueRow(item: item, model: model)
                }
            }
            Divider()
            controls
        }
        .frame(minWidth: 480, minHeight: 440)
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(.tint, lineWidth: 3)
                    .padding(4)
                    .allowsHitTesting(false)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            model.add(urls)
            return !urls.isEmpty
        } isTargeted: { isDropTargeted = $0 }
        .onReceive(NotificationCenter.default.publisher(for: AppDelegate.didOpenFiles)) { notification in
            if let urls = notification.object as? [URL] { model.add(urls) }
        }
        .fileImporter(
            isPresented: $isChoosingFiles,
            allowedContentTypes: ConversionModel.pickableTypes,
            allowsMultipleSelection: true
        ) { result in
            if case .success(let urls) = result { model.add(urls) }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "film.stack")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text("Drop videos or folders here")
                .font(.headline)
            Button("Add Files…") { isChoosingFiles = true }
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var controls: some View {
        VStack(spacing: 12) {
            Form {
                Picker("Quality", selection: $model.quality) {
                    ForEach(Quality.allCases) { Text($0.label).tag($0) }
                }
                Picker("Scaling", selection: $model.scaling) {
                    ForEach(Scaling.allCases) { Text($0.label).tag($0) }
                }
                LabeledContent("Save to") {
                    HStack {
                        if let folder = model.outputFolder {
                            Label(folder.lastPathComponent, systemImage: "folder")
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .help(folder.path)
                        } else {
                            Text("Asked when you convert")
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button(model.outputFolder == nil ? "Choose…" : "Change…") { model.chooseOutputFolder() }
                    }
                }
            }
            .disabled(model.isConverting)

            if let notice = model.notice {
                Label(notice, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack {
                Button("Add Files…") { isChoosingFiles = true }
                Button("Clear") { model.clear() }
                    .disabled(model.items.isEmpty || model.isConverting)
                Spacer()
                Text(summary)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if model.isConverting {
                    Button("Cancel") { model.cancel() }
                } else {
                    Button(model.pending.count > 1 ? "Convert \(model.pending.count) Videos" : "Convert for PSP") {
                        model.convertAll()
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.pending.isEmpty)
                }
            }
        }
        .padding(16)
    }

    private var summary: String {
        if model.isConverting {
            return "Converting \(min(model.finishedCount + 1, model.items.count)) of \(model.items.count)"
        }
        let pending = model.pending
        if !pending.isEmpty {
            return "About \(model.estimatedSize(of: pending)) total"
        }
        return model.items.isEmpty ? "" : "All done"
    }
}

private struct QueueRow: View {
    let item: QueueItem
    let model: ConversionModel
    @State private var isChoosingThumbnail = false

    var body: some View {
        HStack(spacing: 12) {
            thumbnailButton
            VStack(alignment: .leading, spacing: 2) {
                Text(item.source.url.lastPathComponent)
                    .lineLimit(1)
                    .truncationMode(.middle)
                detail
                    .font(.callout)
                    .lineLimit(2)
            }
            Spacer()
            status
        }
        .padding(.vertical, 4)
    }

    /// The thumbnail this video will get; click to pick a different frame or none.
    private var thumbnailButton: some View {
        Button {
            isChoosingThumbnail = true
        } label: {
            ThumbnailImage(image: item.thumbnail, placeholder: item.selectedThumbnail == nil ? "nosign" : "photo")
                .frame(width: 64, height: 48)
        }
        .buttonStyle(.plain)
        .disabled(item.thumbnails.isEmpty)
        .help("Click to choose the thumbnail shown on the PSP; right-click to export it")
        .contextMenu {
            if let image = item.thumbnail {
                Button("Export Thumbnail…") { model.exportThumbnail(image, for: item) }
            }
        }
        .popover(isPresented: $isChoosingThumbnail, arrowEdge: .trailing) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Thumbnail shown on the PSP")
                    .font(.headline)
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(120), spacing: 10), count: 3), spacing: 10) {
                    ForEach(item.thumbnails.indices, id: \.self) { index in
                        thumbnailChoice(index) {
                            ThumbnailImage(image: item.thumbnails[index], placeholder: "photo")
                        }
                    }
                }
                Button {
                    choose(nil)
                } label: {
                    Label("No thumbnail", systemImage: item.selectedThumbnail == nil ? "checkmark" : "nosign")
                }
            }
            .padding(14)
        }
    }

    private func thumbnailChoice(_ index: Int, @ViewBuilder label: () -> some View) -> some View {
        Button {
            choose(index)
        } label: {
            label()
                .frame(width: 120, height: 90)
                .overlay {
                    if index == item.selectedThumbnail {
                        RoundedRectangle(cornerRadius: 4).strokeBorder(.tint, lineWidth: 3)
                    }
                }
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Export Thumbnail…") {
                isChoosingThumbnail = false
                model.exportThumbnail(item.thumbnails[index], for: item)
            }
        }
    }

    private func choose(_ selection: Int?) {
        model.selectThumbnail(selection, for: item)
        isChoosingThumbnail = false
    }

    @ViewBuilder
    private var detail: some View {
        switch item.status {
        case .failed(let message):
            Text(message).foregroundStyle(.red)
        case .finished(let url):
            Text("Saved as \(url.lastPathComponent)").foregroundStyle(.secondary)
        case .waiting, .converting:
            Text(sourceSummary).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var status: some View {
        switch item.status {
        case .waiting:
            removeButton
        case .converting(let fraction):
            ProgressView(value: fraction)
                .frame(width: 80)
            Text(fraction.formatted(.percent.precision(.fractionLength(0))))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 38, alignment: .trailing)
        case .finished(let url):
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
            Button("Show in Finder", systemImage: "magnifyingglass") { model.reveal(url) }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .help("Show in Finder")
            removeButton
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
            removeButton
        }
    }

    private var removeButton: some View {
        Button("Remove", systemImage: "xmark.circle.fill") { model.remove(item) }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help("Remove from list")
    }

    private var sourceSummary: String {
        let source = item.source
        let duration = Duration.seconds(source.duration.rounded())
            .formatted(.time(pattern: source.duration >= 3600 ? .hourMinuteSecond : .minuteSecond))
        let size = "\(Int(source.displaySize.width)) × \(Int(source.displaySize.height))"
        let fps = source.frameRate.formatted(.number.precision(.fractionLength(0...2)))
        return "\(size) · \(fps) fps · \(duration)" + (source.hasAudio ? "" : " · no audio")
            + " → about \(model.estimatedSize(of: [item]))"
    }
}

/// A 4:3 thumbnail, or a placeholder symbol when there isn't one.
private struct ThumbnailImage: View {
    let image: CGImage?
    /// Symbol shown when there's no image: still loading, or no thumbnail wanted.
    let placeholder: String

    var body: some View {
        Group {
            if let image {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .interpolation(.high)
            } else {
                Rectangle()
                    .fill(.quaternary)
                    .overlay { Image(systemName: placeholder).foregroundStyle(.secondary) }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }
}

#Preview {
    ContentView()
}
