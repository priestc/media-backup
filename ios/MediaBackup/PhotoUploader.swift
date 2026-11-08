import Combine
import Foundation
import Photos
import UIKit

@MainActor
class PhotoUploader: ObservableObject {
    @Published var isRunning     = false
    @Published var statusMessage = "Not run since the app opened"
    @Published var uploadedCount = 0
    @Published var failedCount   = 0
    @Published var totalPending  = 0
    @Published var currentFile   = ""

    private static let uploadedKey = "uploadedLocalIdentifiers"
    private var shouldStop = false

    /// Assets Start Backup has uploaded or found on the server (background uploads aren't
    /// recorded here).
    static var uploadedIDs: Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: uploadedKey) ?? [])
    }

    private func markUploaded(_ id: String) {
        var ids = Self.uploadedIDs
        ids.insert(id)
        UserDefaults.standard.set(Array(ids), forKey: Self.uploadedKey)
    }

    static func forgetUploaded(_ id: String) {
        var ids = uploadedIDs
        guard ids.remove(id) != nil else { return }
        UserDefaults.standard.set(Array(ids), forKey: uploadedKey)
    }

    func stop() { shouldStop = true }

    /// Uploads every photo and video not yet on the server over HTTPS, the same way the
    /// background uploader does. Catches up on media from before automatic upload was on.
    ///
    /// With `local`, everything goes straight to the server over the home network (Local Sync)
    /// instead of through flightlogg.in or Tailscale, and the screen stays on meanwhile.
    func startBackup(local: Bool = false) async {
        guard !isRunning else { return }
        isRunning     = true
        shouldStop    = false
        uploadedCount = 0
        failedCount   = 0
        totalPending  = 0
        if local { UIApplication.shared.isIdleTimerDisabled = true }
        defer {
            if local {
                ServerAPI.endLocalSession()
                UIApplication.shared.isIdleTimerDisabled = false
            }
        }

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

        // Assets not yet recorded as uploaded
        let fetchOptions = PHFetchOptions()
        fetchOptions.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
        let alreadyUploaded = Self.uploadedIDs
        var candidates: [(asset: PHAsset, filename: String)] = []
        PHAsset.fetchAssets(with: fetchOptions).enumerateObjects { asset, _, _ in
            if !alreadyUploaded.contains(asset.localIdentifier) {
                candidates.append((asset, asset.backupFilename))
            }
        }

        // Ask the server which of those it already has (e.g. from automatic upload)
        if local {
            statusMessage = "Finding the server on the local network…"
            do {
                _ = try await ServerAPI.startLocalSession()
            } catch {
                statusMessage = "Local Sync could not start: \(error.localizedDescription)"
                isRunning = false
                return
            }
        } else {
            await ServerAPI.selectServer()
        }
        statusMessage = "Checking server…"
        var pending: [(asset: PHAsset, filename: String)] = []
        do {
            for start in stride(from: 0, to: candidates.count, by: 500) {
                let batch = candidates[start..<min(start + 500, candidates.count)]
                let present = try await ServerAPI.present(batch.map(\.filename))
                for candidate in batch {
                    if present.contains(candidate.filename) {
                        markUploaded(candidate.asset.localIdentifier)
                    } else {
                        pending.append(candidate)
                    }
                }
                if shouldStop { break }
            }
        } catch {
            statusMessage = "Could not reach the server: \(error.localizedDescription)"
            isRunning = false
            return
        }

        if pending.isEmpty || shouldStop {
            statusMessage = shouldStop ? "Stopped." : "✓ Everything is backed up."
            isRunning = false
            return
        }
        await upload(pending)
    }

    /// Uploads the given recent items the server doesn't have yet (the front screen's Sync Now).
    func syncNow(_ items: [(asset: PHAsset, filename: String)]) async {
        guard !isRunning, !items.isEmpty else { return }
        isRunning     = true
        shouldStop    = false
        uploadedCount = 0
        failedCount   = 0
        await ServerAPI.selectServer()
        await upload(items)
    }

    /// Uploads `pending` one at a time, reporting progress; clears `isRunning` when done.
    private func upload(_ pending: [(asset: PHAsset, filename: String)]) async {
        totalPending = pending.count
        for (i, item) in pending.enumerated() {
            if shouldStop { break }

            currentFile  = item.filename
            statusMessage = "Uploading \(i + 1)/\(pending.count): \(item.filename)"

            do {
                let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(item.filename)
                defer { try? FileManager.default.removeItem(at: tempURL) }
                try await writeAssetToFile(item.asset, destination: tempURL)
                try await ServerAPI.upload(tempURL, as: item.filename)
                markUploaded(item.asset.localIdentifier)
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

    private func writeAssetToFile(_ asset: PHAsset, destination: URL) async throws {
        guard let resource = asset.backupResource else {
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
