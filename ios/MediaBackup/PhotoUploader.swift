import Combine
import Foundation
import Photos
import UIKit

@MainActor
class PhotoUploader: ObservableObject {
    @Published var isRunning      = false
    @Published var statusMessage  = "Tap 'Start Backup' to begin"
    @Published var uploadedCount  = 0
    @Published var failedCount    = 0
    @Published var totalPending   = 0
    @Published var currentFile    = ""

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

    func stop() {
        shouldStop = true
    }

    func startBackup(localURL: String, tailscaleURL: String, apiKey: String) async {
        guard !isRunning else { return }
        isRunning   = true
        shouldStop  = false
        uploadedCount = 0
        failedCount   = 0

        // Photo library authorization
        let authStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        if authStatus == .notDetermined {
            let result = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
            guard result == .authorized || result == .limited else {
                statusMessage = "Photo access denied. Enable it in Settings → Privacy → Photos."
                isRunning = false
                return
            }
        } else if authStatus == .denied || authStatus == .restricted {
            statusMessage = "Photo access denied. Enable it in Settings → Privacy → Photos."
            isRunning = false
            return
        }

        // Resolve active server URL
        statusMessage = "Connecting to server…"
        guard let baseURL = await resolveBaseURL(local: localURL, tailscale: tailscaleURL, apiKey: apiKey) else {
            statusMessage = "Could not reach server. Check Settings."
            isRunning = false
            return
        }

        // Fetch all assets not yet uploaded
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

        for (i, asset) in pending.enumerated() {
            if shouldStop { break }

            let filename = assetFilename(asset)
            currentFile  = filename
            statusMessage = "Uploading \(i + 1)/\(pending.count): \(filename)"

            do {
                try await uploadAsset(asset, filename: filename, baseURL: baseURL, apiKey: apiKey)
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

    // MARK: - URL resolution

    private func resolveBaseURL(local: String, tailscale: String, apiKey: String) async -> String? {
        for raw in [local, tailscale] {
            if let base = normalizeURL(raw), await canReach(baseURL: base, apiKey: apiKey) {
                return base
            }
        }
        return nil
    }

    private func canReach(baseURL: String, apiKey: String) async -> Bool {
        guard let url = URL(string: "\(baseURL)/status") else { return false }
        var req = URLRequest(url: url, timeoutInterval: 5)
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        return (try? await URLSession.shared.data(for: req)) != nil
    }

    private func normalizeURL(_ raw: String) -> String? {
        var s = raw.trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty else { return nil }
        if !s.hasPrefix("http") { s = "http://" + s }
        if s.hasSuffix("/") { s = String(s.dropLast()) }
        return s
    }

    // MARK: - Upload

    private func uploadAsset(_ asset: PHAsset, filename: String, baseURL: String, apiKey: String) async throws {
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        try await writeAssetToFile(asset, destination: tempURL)

        let takenAt  = asset.creationDate.map { ISO8601DateFormatter().string(from: $0) } ?? ""
        let device   = UIDevice.current.name
        let mimeType = asset.mediaType == .video ? "video/mp4" : "image/jpeg"

        guard let uploadURL = URL(string: "\(baseURL)/upload") else { throw URLError(.badURL) }

        let boundary = UUID().uuidString
        var body = Data()

        func field(_ name: String, _ value: String) {
            body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".data(using: .utf8)!)
        }

        // File part
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: \(mimeType)\r\n\r\n".data(using: .utf8)!)
        body.append(try Data(contentsOf: tempURL))
        body.append("\r\n".data(using: .utf8)!)

        field("filename", filename)
        field("taken_at", takenAt)
        field("device_name", device)
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)

        var request = URLRequest(url: uploadURL, timeoutInterval: 300)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = body

        let (_, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
    }

    // MARK: - Asset extraction

    private func writeAssetToFile(_ asset: PHAsset, destination: URL) async throws {
        let resources = PHAssetResource.assetResources(for: asset)
        guard let resource = resources.first(where: {
            $0.type == .photo || $0.type == .video || $0.type == .fullSizePhoto || $0.type == .fullSizeVideo
        }) ?? resources.first else {
            throw URLError(.cannotLoadFromNetwork)
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let options = PHAssetResourceRequestOptions()
            options.isNetworkAccessAllowed = true
            PHAssetResourceManager.default().writeData(for: resource, toFile: destination, options: options) { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            }
        }
    }

    private func assetFilename(_ asset: PHAsset) -> String {
        let resources = PHAssetResource.assetResources(for: asset)
        if let name = resources.first?.originalFilename, !name.isEmpty { return name }
        let ext = asset.mediaType == .video ? "mp4" : "jpg"
        return "\(asset.localIdentifier.prefix(8)).\(ext)"
    }
}
