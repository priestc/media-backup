import ExtensionFoundation
import Foundation
import OSLog
import Photos

private let log = Logger(subsystem: "io.github.priestc.MediaBackup.Uploader", category: "upload")

/// Launched by iOS when there are new photos/videos. Hands each one to the system as an
/// upload job (`PUT <base>/files/<device>/<filename>`); iOS performs the upload itself,
/// even if this extension or the app is no longer running.
@main
final class MediaBackupUploader: PHBackgroundResourceUploadJobExtension {
    required init() {}

    func processJobs() async -> PHBackgroundResourceUploadProcessingResult {
        do {
            return try await process()
        } catch {
            log.error("processing failed: \(error.localizedDescription, privacy: .public)")
            return .failure
        }
    }

    func willTerminate() async {
        // State is saved after every step, so there is nothing to flush.
    }

    private let library = PHPhotoLibrary.shared()

    private func process() async throws -> PHBackgroundResourceUploadProcessingResult {
        let defaults = SharedConfig.defaults
        guard let base = SharedConfig.uploadURLBase,
              let publicKey = defaults.string(forKey: SharedConfig.publicKeyKey),
              let deviceName = defaults.string(forKey: SharedConfig.deviceNameKey) else {
            log.info("not configured; open the app")
            return .completed
        }

        // 1. Give failed uploads one more try.
        let retryable = jobs(.retry)
        if !retryable.isEmpty {
            try await library.performChanges {
                for job in retryable {
                    PHAssetResourceUploadJobChangeRequest(for: job)?.retry(destination: nil)
                }
            }
        }

        // 2. Acknowledge finished jobs to free capacity. Ones that failed even after the
        //    retry go back in the queue so a later run tries them again.
        let finished = jobs(.acknowledge)
        let failedIDs = finished
            .filter { $0.state == .failed }
            .compactMap { PHAssetResource.assetResource(forUploadJob: $0)?.assetLocalIdentifier }
        if !finished.isEmpty {
            try await library.performChanges {
                for job in finished {
                    PHAssetResourceUploadJobChangeRequest(for: job)?.acknowledge()
                }
            }
        }

        // 3. Queue photos/videos added since last time.
        var queue = defaults.stringArray(forKey: SharedConfig.queueKey) ?? []
        queue += failedIDs
        queue += newAssetIdentifiers()
        var seen = Set<String>()
        queue = queue.filter { seen.insert($0).inserted }
        defaults.set(queue, forKey: SharedConfig.queueKey)

        // 4. Create as many upload jobs as there is room for.
        let capacity = max(0, PHAssetResourceUploadJob.jobLimit - jobs(.process).count)
        let batch = Array(queue.prefix(capacity))
        if !batch.isEmpty {
            var uploads: [(URLRequest, PHAssetResource)] = []
            PHAsset.fetchAssets(withLocalIdentifiers: batch, options: nil).enumerateObjects { asset, _, _ in
                guard let resource = Self.primaryResource(asset) else { return }
                uploads.append((Self.request(base: base, device: deviceName,
                                             filename: Self.filename(asset), publicKey: publicKey),
                                resource))
            }
            if !uploads.isEmpty {
                try await library.performChanges {
                    for (destination, resource) in uploads {
                        _ = PHAssetResourceUploadJobChangeRequest.creationRequestForJob(
                            destination: destination, resource: resource)
                    }
                }
            }
            queue.removeFirst(batch.count)
            defaults.set(queue, forKey: SharedConfig.queueKey)
            log.info("created \(uploads.count) upload job(s), \(queue.count) still queued")
        }

        return queue.isEmpty ? .completed : .processing
    }

    private func jobs(_ action: PHAssetResourceUploadJob.Action) -> [PHAssetResourceUploadJob] {
        let result = PHAssetResourceUploadJob.fetchJobs(action: action, options: nil)
        return (0..<result.count).map { result.object(at: $0) }
    }

    /// Identifiers of assets inserted since the saved change token, advancing the token.
    private func newAssetIdentifiers() -> [String] {
        let current = library.currentChangeToken
        defer { SharedConfig.changeToken = PHPersistentChangeTokenBox(current) }
        guard let since = SharedConfig.changeToken?.token else { return [] }

        var ids: [String] = []
        do {
            for change in try library.fetchPersistentChanges(since: since) {
                if let details = try? change.changeDetails(for: .asset) {
                    ids += details.insertedLocalIdentifiers
                }
            }
        } catch {
            // Token expired (history purged) — start over from now; Start Backup catches up.
            log.error("change history unavailable: \(error.localizedDescription, privacy: .public)")
        }
        return ids
    }

    // Same resource and filename choice as PhotoUploader, so the server sees the same file
    // whether it arrives here or via SFTP, and skips duplicates.
    private static func primaryResource(_ asset: PHAsset) -> PHAssetResource? {
        let resources = PHAssetResource.assetResources(for: asset)
        return resources.first(where: {
            $0.type == .photo || $0.type == .video ||
            $0.type == .fullSizePhoto || $0.type == .fullSizeVideo
        }) ?? resources.first
    }

    private static func filename(_ asset: PHAsset) -> String {
        let resources = PHAssetResource.assetResources(for: asset)
        if let name = resources.first?.originalFilename, !name.isEmpty { return name }
        let ext = asset.mediaType == .video ? "mp4" : "jpg"
        return "\(asset.localIdentifier.prefix(8)).\(ext)"
    }

    private static func request(base: URL, device: String, filename: String, publicKey: String) -> URLRequest {
        let url = base.appending(component: "files")
            .appending(component: device)
            .appending(component: filename)
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue("Bearer \(publicKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        return request
    }
}
