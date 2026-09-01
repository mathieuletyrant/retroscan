import RetroscanKit
import SwiftUI

struct ContentView: View {
    @EnvironmentObject var model: ScanModel

    var body: some View {
        NavigationSplitView {
            SettingsPane()
                .navigationSplitViewColumnWidth(min: 280, ideal: 320, max: 380)
        } detail: {
            PhotoGrid()
                .safeAreaInset(edge: .bottom, spacing: 0) { StatusBar() }
        }
        .frame(minWidth: 900, minHeight: 560)
        .toolbar {
            ToolbarItemGroup {
                Button {
                    model.scanOnce()
                } label: {
                    Label("Scan", systemImage: "scanner")
                        .labelStyle(.titleAndIcon)
                }
                .disabled(model.busy || model.watching)
                .help("Scan now")

                Button {
                    model.toggleWatch()
                } label: {
                    Label(model.watching ? "Stop watching" : "Watch",
                          systemImage: "dot.radiowaves.left.and.right")
                        .labelStyle(.titleAndIcon)
                        .foregroundStyle(model.watching ? Color.red : Color.primary)
                }
                .disabled(model.busy)
                .help("Register on the printer's Scan to PC menu and scan on each button press")

                Button {
                    model.reprocessLastScan()
                } label: {
                    Label("Re-process", systemImage: "arrow.triangle.2.circlepath")
                        .labelStyle(.titleAndIcon)
                }
                .disabled(!model.canReprocess)
                .help("Re-run cropping on the last scan with the current settings — no rescan")

                Button {
                    model.clearAll()
                } label: {
                    Label("Clear Grid", systemImage: "xmark.bin")
                        .labelStyle(.titleAndIcon)
                }
                .disabled(model.photos.isEmpty || model.busy)
                .help("Remove every photo from the grid — files on disk and original scans are kept; open the album to bring them back")
            }
        }
        .alert("retroscan", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
    }
}

// MARK: - Sidebar

struct SettingsPane: View {
    @EnvironmentObject var model: ScanModel
    @State private var confirmingCleanCache = false

    var body: some View {
        Form {
            Section("Scanner") {
                Picker("Device", selection: $model.selectedScanner) {
                    if model.scanners.isEmpty {
                        Text(model.discovering ? "Searching…" : "None found")
                            .tag(String?.none)
                    }
                    ForEach(model.scanners, id: \.name) { scanner in
                        Text(scanner.name).tag(String?.some(scanner.name))
                    }
                }
                Button {
                    model.refreshScanners()
                } label: {
                    if model.discovering {
                        Text("Searching…")
                    } else {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                }
                .disabled(model.discovering)
            }

            Section("Scan") {
                Picker("Resolution", selection: $model.resolution) {
                    ForEach([100, 150, 200, 300, 600], id: \.self) { dpi in
                        Text("\(dpi) dpi").tag(dpi)
                    }
                }
                Toggle("Grayscale", isOn: $model.grayscale)
                Picker("Crop", selection: $model.crop) {
                    ForEach(CropStrategy.allCases, id: \.self) { strategy in
                        Text(strategy.rawValue.capitalized).tag(strategy)
                    }
                }
                Toggle("Auto-rotate (faces upright)", isOn: $model.autoRotate)
            }

            Section {
                LabeledContent("Folder") {
                    Text(model.outputDirectory.lastPathComponent)
                        .lineLimit(1)
                        .truncationMode(.head)
                        .help(model.outputDirectory.path)
                }
                HStack {
                    Button("Open Album…") { model.chooseOutputDirectory() }
                        .help("Choose the album's folder — an existing album reloads its photos and metadata")
                    Button {
                        model.revealOutputFolder()
                    } label: {
                        Label("Show in Finder", systemImage: "folder")
                    }
                }
                TextField("Title", text: $model.title, prompt: Text("Holidays 1995"))
                TextField("Description", text: $model.caption)
                TextField("Author", text: $model.author)
                TextField("Keywords", text: $model.keywords, prompt: Text("photos, family"))
                TextField("Date taken", text: $model.dateTaken, prompt: Text("1995 or 1995-07-14"))
                if !model.dateTakenValid {
                    Text("Use 1995, 1995-07 or 1995-07-14")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            } header: {
                Text("Album")
            } footer: {
                Text("An album is a folder of saved photos. Open it again anytime: its photos come back, still croppable and editable.")
                    .foregroundStyle(.secondary)
            }

            Section("Saving") {
                LabeledContent("JPEG quality") {
                    Text("\(Int((model.quality * 100).rounded())) %")
                        .foregroundStyle(.secondary)
                }
                Slider(value: $model.quality, in: 0.5...1.0) {
                    Text("JPEG quality")
                }
                .labelsHidden()
            }

            Section("Original Scans") {
                LabeledContent("Disk space", value: model.cacheSizeText)
                    .help("Every scanned page is kept so photo crops stay adjustable — even after saving")
                Button("Delete Original Scans…") {
                    confirmingCleanCache = true
                }
                .disabled(model.cacheBytes == 0 || model.busy)
                .confirmationDialog("Delete all original scans (\(model.cacheSizeText))?",
                                    isPresented: $confirmingCleanCache) {
                    Button("Delete", role: .destructive) { model.deleteOriginalScans() }
                } message: {
                    Text("Photos keep their current crop and saved files stay on disk, but crops can no longer be re-adjusted.")
                }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Photo grid

struct PhotoGrid: View {
    @EnvironmentObject var model: ScanModel

    var body: some View {
        Group {
            if model.photos.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "photo.on.rectangle.angled")
                        .font(.system(size: 44))
                        .foregroundStyle(.tertiary)
                    Text("No photos yet")
                        .font(.title3)
                    Text("Lay prints on the glass and press Scan —\nor start Watch and use the printer's button.\nEvery photo lands in the album automatically.\nDrop a scan JPEG here to replay its cropping.")
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 200, maximum: 320), spacing: 16)],
                              spacing: 16) {
                        ForEach(model.photos) { photo in
                            PhotoCell(photo: photo)
                        }
                    }
                    .padding(16)
                }
            }
        }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            for provider in providers {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url, ["jpg", "jpeg"].contains(url.pathExtension.lowercased()) else { return }
                    DispatchQueue.main.async { model.processFile(url) }
                }
            }
            return true
        }
    }
}

struct PhotoCell: View {
    @EnvironmentObject var model: ScanModel
    let photo: AlbumPhoto
    @State private var showingInfo = false
    @State private var overridesAtOpen: [String]?
    @State private var cropContext: CropEditingContext?

    private var currentOverrides: [String] {
        [model.dateOverride(photo.id).wrappedValue,
         model.captionOverride(photo.id).wrappedValue]
    }

    var body: some View {
        VStack(spacing: 6) {
            Image(decorative: photo.thumbnail, scale: 1)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(maxHeight: 240)
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .shadow(radius: 2)
                .overlay(alignment: .topTrailing) {
                    HStack(spacing: 4) {
                        if model.canEditCrop(photo) {
                            Button {
                                cropContext = model.beginCropEdit(photo)
                            } label: {
                                Image(systemName: "crop")
                            }
                            .help("Adjust the crop on the scanned page")
                            .sheet(item: $cropContext) { context in
                                CropEditorView(context: context) { rect in
                                    model.applyCropEdit(photoID: context.id,
                                                        page: context.page, rect: rect)
                                }
                            }
                        }
                        Button {
                            showingInfo = true
                        } label: {
                            Image(systemName: photo.hasOverrides ? "info.circle.fill" : "info.circle")
                        }
                        .help("Set a date or description just for this photo")
                        .popover(isPresented: $showingInfo) {
                            PhotoInfoPopover(photo: photo)
                        }
                        // A saved photo's overrides are re-embedded into the
                        // JPEG when the popover closes with changed values.
                        .onChange(of: showingInfo) { shown in
                            if shown {
                                overridesAtOpen = currentOverrides
                            } else {
                                if overridesAtOpen != currentOverrides {
                                    model.commitOverrides(photo.id)
                                }
                                overridesAtOpen = nil
                            }
                        }
                        Button {
                            model.rotate(photo)
                        } label: {
                            Image(systemName: "rotate.right")
                        }
                        .help("Rotate 90° clockwise")
                        .disabled(model.busy)
                        Button {
                            model.delete(photo)
                        } label: {
                            Image(systemName: "trash")
                        }
                        .help("Move this photo's file to the Trash")
                    }
                    .buttonStyle(.borderless)
                    .padding(5)
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 6))
                    .padding(6)
                }

            HStack(spacing: 4) {
                Text(photo.savedURL.lastPathComponent)
                    .help("\(photo.pixelWidth)×\(photo.pixelHeight) px")
                if photo.hasOverrides {
                    Image(systemName: "info.circle.fill")
                        .foregroundStyle(.blue)
                        .help([photo.dateOverride, photo.captionOverride]
                            .filter { !$0.isEmpty }.joined(separator: " — "))
                }
                Text("· \(photo.method)")
                    .foregroundStyle(.secondary)
            }
            .font(.caption)
            .lineLimit(1)
        }
    }
}

/// Per-photo date/description overrides; an empty field inherits the album
/// value from the sidebar.
struct PhotoInfoPopover: View {
    @EnvironmentObject var model: ScanModel
    let photo: AlbumPhoto

    private var dateValid: Bool {
        let text = model.dateOverride(photo.id).wrappedValue
        return text.isEmpty || ContentDate(text) != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("This photo only")
                .font(.headline)
            TextField("Date taken", text: model.dateOverride(photo.id),
                      prompt: Text(model.dateTaken.isEmpty ? "1995-07-14" : model.dateTaken))
            if !dateValid {
                Text("Use 1995, 1995-07 or 1995-07-14")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            TextField("Description", text: model.captionOverride(photo.id),
                      prompt: Text(model.caption.isEmpty ? "Description" : model.caption))
            Text("Empty fields inherit the album values.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(width: 280)
    }
}

// MARK: - Crop editor

/// The scanned page with the photo's rectangle over it: drag the corners to
/// resize, drag the inside to move. Apply re-crops from the full-resolution
/// page, taking the frame literally (no tightening, no auto-rotation).
struct CropEditorView: View {
    let context: CropEditingContext
    let onApply: (CGRect) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var rect: CGRect
    @State private var dragStart: CGRect?

    private var pageSize: CGSize {
        CGSize(width: context.page.width, height: context.page.height)
    }

    init(context: CropEditingContext, onApply: @escaping (CGRect) -> Void) {
        self.context = context
        self.onApply = onApply
        _rect = State(initialValue: context.rect)
    }

    var body: some View {
        VStack(spacing: 12) {
            GeometryReader { geo in
                let scale = min(geo.size.width / pageSize.width,
                                geo.size.height / pageSize.height)
                let shown = CGSize(width: pageSize.width * scale,
                                   height: pageSize.height * scale)
                let origin = CGPoint(x: (geo.size.width - shown.width) / 2,
                                     y: (geo.size.height - shown.height) / 2)
                let viewRect = CGRect(x: origin.x + rect.minX * scale,
                                      y: origin.y + rect.minY * scale,
                                      width: rect.width * scale,
                                      height: rect.height * scale)

                ZStack(alignment: .topLeading) {
                    Image(decorative: context.page, scale: 1)
                        .resizable()
                        .frame(width: shown.width, height: shown.height)
                        .offset(x: origin.x, y: origin.y)

                    // Dim everything outside the crop.
                    Path { path in
                        path.addRect(CGRect(x: origin.x, y: origin.y,
                                            width: shown.width, height: shown.height))
                        path.addRect(viewRect)
                    }
                    .fill(Color.black.opacity(0.45), style: FillStyle(eoFill: true))

                    Rectangle()
                        .strokeBorder(Color.accentColor, lineWidth: 2)
                        .frame(width: viewRect.width, height: viewRect.height)
                        .offset(x: viewRect.minX, y: viewRect.minY)
                        .contentShape(Rectangle())
                        .gesture(moveGesture(scale: scale))

                    ForEach(corners, id: \.name) { corner in
                        Circle()
                            .fill(Color.accentColor)
                            .frame(width: 14, height: 14)
                            .overlay(Circle().strokeBorder(.white, lineWidth: 2))
                            // A generous invisible hit zone around the dot.
                            .frame(width: 36, height: 36)
                            .contentShape(Circle())
                            .position(x: viewRect.minX + corner.unit.x * viewRect.width,
                                      y: viewRect.minY + corner.unit.y * viewRect.height)
                            .gesture(cornerGesture(corner, scale: scale))
                    }
                }
            }

            HStack {
                Text("\(Int(rect.width))×\(Int(rect.height)) px")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Apply") {
                    onApply(rect)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        // Sheets size to their content's ideal size: claim most of the
        // screen so the page is workable, while staying user-resizable.
        .frame(minWidth: 720, idealWidth: idealSheetSize.width, maxWidth: .infinity,
               minHeight: 540, idealHeight: idealSheetSize.height, maxHeight: .infinity)
    }

    private var idealSheetSize: CGSize {
        let visible = NSScreen.main?.visibleFrame.size ?? CGSize(width: 1440, height: 900)
        return CGSize(width: visible.width * 0.85, height: visible.height * 0.82)
    }

    // MARK: Gestures

    private struct Corner {
        let name: String
        let unit: CGPoint  // (0,0) top-left … (1,1) bottom-right
    }

    private var corners: [Corner] {
        [Corner(name: "tl", unit: CGPoint(x: 0, y: 0)),
         Corner(name: "tr", unit: CGPoint(x: 1, y: 0)),
         Corner(name: "bl", unit: CGPoint(x: 0, y: 1)),
         Corner(name: "br", unit: CGPoint(x: 1, y: 1))]
    }

    private func cornerGesture(_ corner: Corner, scale: CGFloat) -> some Gesture {
        DragGesture()
            .onChanged { value in
                let start = dragStart ?? rect
                dragStart = start
                let dx = value.translation.width / scale
                let dy = value.translation.height / scale
                let minSide: CGFloat = 40
                var minX = start.minX, maxX = start.maxX
                var minY = start.minY, maxY = start.maxY
                if corner.unit.x == 0 {
                    minX = min(max(0, start.minX + dx), maxX - minSide)
                } else {
                    maxX = max(min(pageSize.width, start.maxX + dx), minX + minSide)
                }
                if corner.unit.y == 0 {
                    minY = min(max(0, start.minY + dy), maxY - minSide)
                } else {
                    maxY = max(min(pageSize.height, start.maxY + dy), minY + minSide)
                }
                rect = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
            }
            .onEnded { _ in dragStart = nil }
    }

    private func moveGesture(scale: CGFloat) -> some Gesture {
        DragGesture()
            .onChanged { value in
                let start = dragStart ?? rect
                dragStart = start
                let dx = value.translation.width / scale
                let dy = value.translation.height / scale
                let x = min(max(0, start.minX + dx), pageSize.width - start.width)
                let y = min(max(0, start.minY + dy), pageSize.height - start.height)
                rect = CGRect(x: x, y: y, width: start.width, height: start.height)
            }
            .onEnded { _ in dragStart = nil }
    }
}

// MARK: - Status bar

struct StatusBar: View {
    @EnvironmentObject var model: ScanModel

    var body: some View {
        HStack(spacing: 8) {
            if model.busy || model.watching {
                ProgressView()
                    .controlSize(.small)
            }
            Text(model.status)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer()
            if !model.photos.isEmpty {
                Text("\(model.photos.count) photo\(model.photos.count > 1 ? "s" : "")")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(.bar)
    }
}
