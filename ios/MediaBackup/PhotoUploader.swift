import Combine
import Foundation
import Photos
import UIKit

@MainActor
class PhotoUploader: ObservableObject {
    @Published var isRunning     = false
    @Published var statusMessage = "Tap 'Start Backup' to begin"
    @Published var uploadedCount = 0
    @Published var failedCount   = 0
    @Published var totalPending  = 0
    @Published var currentFile   = ""

    private let uploadedKey = "uploadedLocalIdentifiers"
    private var shouldStop  = false

    private var uploadedIDs: Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: uploadedKey) ?? [])
    }

    private func markUploaded(_ id: String) {
        var ids = uploadedIDs
        ids.insert(id)
        UserDefaults.standard.set(Array(ids), forKey: uploadedKey)
    }

    func stop() { shouldStop = true }

    func startBackup(
        localHost: String, tailscaleHost: String,
        port: Int, username: String, remotePath: String
    ) async {
        guard !isRunning else { return }
        isRunning     = true
        shouldStop    = false
        uploadedCount = 0
        failedCount   = 0

        // Photo library authorization
        let auth = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        if auth == .notDetermined {
            let result = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
            guard result == .authorized || result == .limited else {
                statusMessage = "Photo access denied. Enable it in Settings → Privacy → Photos."
                isRunning = false
                return
            }
        } else if auth == .denied || auth == .restricted {
            statusMessage = "Photo access denied. Enable it in Settings → Privacy → Photos."
            isRunning = false
            return
        }

        // Connect via SSH — try local first, then Tailscale
        statusMessage = "Connecting…"
        let sftp = SFTPService()
        var connected = false
        for host in [localHost, tailscaleHost] {
            let h = host.trimmingCharacters(in: .whitespaces)
            guard !h.isEmpty else { continue }
            do {
                try await sftp.connect(host: h, port: port, username: username)
                connected = true
                break
            } catch {}
        }
        guard connected else {
            statusMessage = "Could not connect. Check SSH settings."
            isRunning = false
            return
        }
        defer { Task { await sftp.disconnect() } }

        // Fetch assets not yet uploaded
        let fetchOptions = PHFetchOptions()
        fetchOptions.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
        let allAssets = PHAsset.fetchAssets(with: fetchOptions)

        let alreadyUploaded = uploadedIDs
        var pending: [PHAsset] = []
        allAssets.enumerateObjects { asset, _, _ in
            if !alreadyUploaded.contains(asset.localIdentifier) {
                pending.append(asset)
            }
        }

        totalPending = pending.count
        if pending.isEmpty {
            statusMessage = "✓ Everything is backed up."
            isRunning = false
            return
        }

        statusMessage = "Uploading \(pending.count) file(s)…"
        let deviceName = UIDevice.current.name

        for (i, asset) in pending.enumerated() {
            if shouldStop { break }

            let filename = assetFilename(asset)
            currentFile  = filename
            statusMessage = "Uploading \(i + 1)/\(pending.count): \(filename)"

            do {
                let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
                defer { try? FileManager.default.removeItem(at: tempURL) }
                try await writeAssetToFile(asset, destination: tempURL)

                let data = try Data(contentsOf: tempURL)
                let dateStr = datePath(asset.creationDate ?? Date())
                let remoteFile = "\(remotePath)/\(deviceName)/\(dateStr)/\(filename)"

                let exists = await sftp.fileExists(atPath: remoteFile)
                if !exists {
                    try await sftp.upload(data: data, toPath: remoteFile)
                }
                markUploaded(asset.localIdentifier)
                uploadedCount += 1
            } catch {
                failedCount += 1
            }
        }

        currentFile = ""
        if shouldStop {
            statusMessage = "Stopped. \(uploadedCount) uploaded."
        } else if failedCount == 0 {
            statusMessage = "✓ Backup complete. \(uploadedCount) file(s) uploaded."
        } else {
            statusMessage = "Done. \(uploadedCount) uploaded, \(failedCount) failed."
        }
        isRunning = false
    }

    // MARK: - Helpers

    private func datePath(_ date: Date) -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy/MM/dd"
        return fmt.string(from: date)
    }

    private func assetFilename(_ asset: PHAsset) -> String {
        let resources = PHAssetResource.assetResources(for: asset)
        if let name = resources.first?.originalFilename, !name.isEmpty { return name }
        let ext = asset.mediaType == .video ? "mp4" : "jpg"
        return "\(asset.localIdentifier.prefix(8)).\(ext)"
    }

    private func writeAssetToFile(_ asset: PHAsset, destination: URL) async throws {
        let resources = PHAssetResource.assetResources(for: asset)
        guard let resource = resources.first(where: {
            $0.type == .photo || $0.type == .video ||
            $0.type == .fullSizePhoto || $0.type == .fullSizeVideo
        }) ?? resources.first else {
            throw URLError(.cannotLoadFromNetwork)
        }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let options = PHAssetResourceRequestOptions()
            options.isNetworkAccessAllowed = true
            PHAssetResourceManager.default().writeData(for: resource, toFile: destination, options: options) { error in
                if let error { cont.resume(throwing: error) } else { cont.resume() }
            }
        }
    }
}
