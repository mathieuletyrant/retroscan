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
                    model.saveAll()
                } label: {
                    Label(model.unsavedCount > 0 ? "Save \(model.unsavedCount)" : "Save",
                          systemImage: "square.and.arrow.down")
                        .labelStyle(.titleAndIcon)
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.busy || model.unsavedCount == 0)
                .help("Write every unsaved photo to the output folder")
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
                Toggle("Segment Anything (SAM)", isOn: $model.useSAM)
                    .help("Neural-network photo detection — helps when a photo edge is nearly white; downloads ~78 MB of models on first use")
                Toggle("Auto-rotate (faces upright)", isOn: $model.autoRotate)
            }

            Section("Metadata") {
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
            }

            Section("Output") {
                LabeledContent("Folder") {
                    Text(model.outputDirectory.path)
                        .lineLimit(1)
                        .truncationMode(.head)
                        .help(model.outputDirectory.path)
                }
                Button("Choose…") { model.chooseOutputDirectory() }
                Toggle("Auto-save incoming scans", isOn: $model.autoSave)
                    .help("Write files as soon as a scan is processed — for hands-off watch sessions")
                Slider(value: $model.quality, in: 0.5...1.0) {
                    Text("JPEG quality")
                }
                Text("JPEG quality: \(model.quality, specifier: "%.2f")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
                    Text("Lay prints on the glass and press Scan —\nor start Watch and use the printer's button.\nDrop a scan JPEG here to replay its cropping.")
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
                .safeAreaInset(edge: .top, spacing: 0) {
                    if model.unsavedCount > 0 {
                        UnsavedBanner()
                    }
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

/// The review-then-save flow made explicit: nothing is on disk until Save.
struct UnsavedBanner: View {
    @EnvironmentObject var model: ScanModel

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(.orange)
            Text("\(model.unsavedCount) photo\(model.unsavedCount > 1 ? "s" : "") not on disk yet — review, then save.")
            Spacer()
            Button {
                model.saveAll()
            } label: {
                Label("Save to “\(model.outputDirectory.lastPathComponent)”",
                      systemImage: "square.and.arrow.down")
            }
            .buttonStyle(.borderedProminent)
            .disabled(model.busy)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
    }
}

struct PhotoCell: View {
    @EnvironmentObject var model: ScanModel
    let photo: PendingPhoto

    var body: some View {
        VStack(spacing: 6) {
            Image(decorative: photo.image, scale: 1)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(maxHeight: 240)
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .shadow(radius: 2)
                .overlay(alignment: .topTrailing) {
                    HStack(spacing: 4) {
                        if photo.savedURL == nil {
                            Button {
                                model.rotate(photo)
                            } label: {
                                Image(systemName: "rotate.right")
                            }
                            .help("Rotate 90° clockwise")
                        }
                        Button {
                            model.remove(photo)
                        } label: {
                            Image(systemName: "trash")
                        }
                        .help(photo.savedURL == nil
                              ? "Discard this photo"
                              : "Remove from the list (the saved file is kept)")
                    }
                    .buttonStyle(.borderless)
                    .padding(5)
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 6))
                    .padding(6)
                }

            HStack(spacing: 4) {
                if let url = photo.savedURL {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text(url.lastPathComponent)
                } else {
                    Image(systemName: "circle.fill")
                        .font(.system(size: 7))
                        .foregroundStyle(.orange)
                        .help("Not saved yet")
                    Text("\(photo.image.width)×\(photo.image.height) px")
                }
                Text("· \(photo.method)")
                    .foregroundStyle(.secondary)
            }
            .font(.caption)
            .lineLimit(1)
        }
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
                Text("\(model.photos.count) photo\(model.photos.count > 1 ? "s" : ""), \(model.unsavedCount) unsaved")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(.bar)
    }
}
