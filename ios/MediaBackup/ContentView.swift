import Photos
import SwiftUI

struct ContentView: View {
    @StateObject private var uploader = PhotoUploader()
    @StateObject private var media = RecentMedia()
    @State private var showSettings = false
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationView {
            List {
                Section { statusRow }

                Section(header: Text("Latest")) {
                    if media.accessDenied {
                        Text("Photo access denied. Enable it in Settings → Privacy → Photos.")
                            .foregroundColor(.secondary)
                    } else if media.items.isEmpty {
                        Text("No photos or videos yet.")
                            .foregroundColor(.secondary)
                    }
                    ForEach(media.items) { item in
                        MediaRow(item: item, status: media.status[item.id] ?? .unknown)
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                deleteButton(item)
                            }
                            .contextMenu { deleteButton(item) }
                    }
                }
            }
            .listStyle(.plain)
            .refreshable { await media.refreshServerStatus() }
            .safeAreaInset(edge: .bottom) { backupButton }
            .navigationTitle("Media Backup")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { showSettings = true } label: {
                        Image(systemName: "gear")
                    }
                }
            }
            .sheet(isPresented: $showSettings) {
                SettingsView()
            }
            .alert("Delete", isPresented: Binding(
                get: { media.errorMessage != nil },
                set: { if !$0 { media.errorMessage = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(media.errorMessage ?? "")
            }
            .task {
                await media.start()
                // Photo access may have just been granted
                BackgroundUpload.configure()
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { Task { await media.refreshServerStatus() } }
            }
            .onChange(of: uploader.uploadedCount) { _, _ in media.updateStatus() }
            .onChange(of: uploader.isRunning) { _, running in
                if !running { Task { await media.refreshServerStatus() } }
            }
        }
    }

    private func deleteButton(_ item: RecentMedia.Item) -> some View {
        Button(role: .destructive) {
            Task { await media.delete(item) }
        } label: {
            Label("Delete Everywhere", systemImage: "trash")
        }
    }

    private var statusRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(uploader.statusMessage, systemImage: statusIcon)
                .font(.subheadline)
                .foregroundColor(statusColor)
            if uploader.isRunning && uploader.totalPending > 0 {
                ProgressView(value: Double(uploader.uploadedCount),
                             total: Double(uploader.totalPending))
                Text("\(uploader.uploadedCount) / \(uploader.totalPending)  \(uploader.currentFile)")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
    }

    private var backupButton: some View {
        Button(action: toggleBackup) {
            Label(
                uploader.isRunning ? "Stop" : "Start Backup",
                systemImage: uploader.isRunning ? "stop.fill" : "arrow.up.to.cloud.fill"
            )
            .frame(maxWidth: .infinity)
            .padding()
            .background(uploader.isRunning ? Color.red : Color.blue)
            .foregroundColor(.white)
            .cornerRadius(12)
            .padding(.horizontal)
            .padding(.bottom, 8)
        }
    }

    private var statusIcon: String {
        if uploader.isRunning { return "arrow.up.circle.fill" }
        if uploader.statusMessage.hasPrefix("✓") { return "checkmark.circle.fill" }
        if uploader.statusMessage.lowercased().contains("error") ||
           uploader.statusMessage.lowercased().contains("denied") ||
           uploader.statusMessage.lowercased().contains("could not") { return "exclamationmark.circle.fill" }
        return "photo.on.rectangle.angled"
    }

    private var statusColor: Color {
        if uploader.isRunning { return .blue }
        if uploader.statusMessage.hasPrefix("✓") { return .green }
        if uploader.statusMessage.lowercased().contains("error") ||
           uploader.statusMessage.lowercased().contains("denied") ||
           uploader.statusMessage.lowercased().contains("could not") { return .red }
        return .secondary
    }

    private func toggleBackup() {
        if uploader.isRunning {
            uploader.stop()
        } else {
            let d = UserDefaults.standard
            Task {
                await uploader.startBackup(
                    localHost:     d.string(forKey: "sshLocalHost")    ?? "",
                    tailscaleHost: d.string(forKey: "sshTailscaleHost") ?? "",
                    port:          Int(d.string(forKey: "sshPort") ?? "22") ?? 22,
                    username:      d.string(forKey: "sshUsername")     ?? "",
                    remotePath:    d.string(forKey: "sshRemotePath")   ?? ""
                )
                // Photo access may have just been granted
                BackgroundUpload.configure()
            }
        }
    }
}

/// One photo or video: a full-width preview, when it was taken, and its backup status.
private struct MediaRow: View {
    let item: RecentMedia.Item
    let status: RecentMedia.Status

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            AssetThumbnail(asset: item.asset)
                .overlay(alignment: .bottomTrailing) {
                    if item.asset.mediaType == .video {
                        Label(duration, systemImage: "video.fill")
                            .font(.caption.bold())
                            .padding(.horizontal, 6).padding(.vertical, 3)
                            .background(.black.opacity(0.6), in: Capsule())
                            .foregroundColor(.white)
                            .padding(8)
                    }
                }
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.asset.creationDate.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "")
                        .font(.subheadline)
                    Text(item.filename)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
                statusLabel
            }
        }
        .padding(.vertical, 4)
    }

    private var statusLabel: some View {
        switch status {
        case .uploaded:
            return Label("On server", systemImage: "checkmark.icloud.fill").foregroundColor(.green)
        case .notUploaded:
            return Label("Not uploaded", systemImage: "icloud.slash").foregroundColor(.orange)
        case .unknown:
            return Label("Unknown", systemImage: "questionmark.circle").foregroundColor(.secondary)
        }
    }

    private var duration: String {
        let s = Int(item.asset.duration.rounded())
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

private struct AssetThumbnail: View {
    let asset: PHAsset
    @State private var image: UIImage?

    /// Wide shots show whole; tall ones are cropped to a square to keep rows a sane height.
    private var aspectRatio: CGFloat {
        guard asset.pixelWidth > 0, asset.pixelHeight > 0 else { return 1 }
        return min(max(CGFloat(asset.pixelWidth) / CGFloat(asset.pixelHeight), 1), 3)
    }

    var body: some View {
        Color(.secondarySystemBackground)
            .aspectRatio(aspectRatio, contentMode: .fit)
            .overlay {
                if let image {
                    Image(uiImage: image).resizable().scaledToFill()
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .task(id: asset.localIdentifier) { image = await load() }
    }

    private func load() async -> UIImage? {
        let options = PHImageRequestOptions()
        options.deliveryMode = .highQualityFormat
        options.isNetworkAccessAllowed = true
        return await withCheckedContinuation { cont in
            PHImageManager.default().requestImage(
                for: asset, targetSize: CGSize(width: 1200, height: 1200),
                contentMode: .aspectFill, options: options
            ) { image, _ in cont.resume(returning: image) }
        }
    }
}
