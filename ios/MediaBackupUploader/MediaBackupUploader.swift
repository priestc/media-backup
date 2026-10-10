import ExtensionFoundation
import Foundation
import OSLog
import Photos

private let log = Logger(subsystem: "io.github.priestc.MediaBackup.Uploader", category: "upload")

/// Launched by iOS when there are new photos/videos. Hands each one to the system as an
/// upload job (`PUT <base>/files/<device>/<filename>`); iOS performs the upload itself,
/// even if this extension or the app is no longer running.
///
/// Follows Apple's "Uploading asset resources in the background" guide: retry only transient
/// failures, return `.processing` when the in-flight job limit is hit, and re-sync when the
/// persistent change history has been pruned past the saved token.
@main
final class MediaBackupUploader: PHBackgroundResourceUploadJobExtension {
    required init() {}

    func processJobs() async -> PHBackgroundResourceUploadProcessingResult {
        do {
            return try await process()
        } catch where Self.isLimitExceeded(error) {
            log.info("in-flight job limit reached; waiting for jobs to finish")
            return .processing
        } catch {
            log.error("processing failed: \(error.localizedDescription, privacy: .public)")
            return .failure
        }
    }

    func willTerminate() async {
        // State is saved after every step, so there is nothing to flush.
    }

    private let library = PHPhotoLibrary.shared()
    private let defaults = SharedConfig.defaults

    /// Set when the change token expired; the next run re-syncs from the last sync date.
    private static let needsResyncKey = "needsResync"
    /// Asset ID → how many times its upload failed permanently (e.g. rejected by the server).
    private static let failureCountsKey = "uploadFailureCounts"
    /// After this many permanent failures an asset is dropped from the queue; Start Backup
    /// still picks it up.
    private static let maxFailures = 3

    private func process() async throws -> PHBackgroundResourceUploadProcessingResult {
        guard let base = SharedConfig.uploadURLBase,
              let apiKey = SharedConfig.apiKey,
              let deviceName = defaults.string(forKey: SharedConfig.deviceNameKey) else {
            log.info("not configured; open the app and pair with the server")
            return .completed
        }
        let server = Server(base: base, device: deviceName, apiKey: apiKey)

        // 1. Retry transient failures (timeouts, lost connection) with the same request.
        //    Permanent ones (rejected by the server) are acknowledged below instead.
        let retryable = jobs(.retry).filter { Self.isTransient($0.error) }
        if !retryable.isEmpty {
            do {
                try await library.performChanges {
                    for job in retryable {
                        PHAssetResourceUploadJobChangeRequest(for: job)?.retry(destination: nil)
                    }
                }
            } catch where Self.isLimitExceeded(error) {
                log.info("no room to retry \(retryable.count) job(s) yet")
            }
        }

        // 2. Acknowledge finished jobs to free capacity. Failed ones are queued again, so
        //    they get a fresh request (e.g. with a newly paired key), up to maxFailures times.
        let finished = jobs(.acknowledge)
        var succeeded: [String] = []
        var failed: [String] = []
        for job in finished {
            guard let id = PHAssetResource.assetResource(forUploadJob: job)?.assetLocalIdentifier else { continue }
            if job.state == .succeeded { succeeded.append(id) }
            if job.state == .failed {
                failed.append(id)
                log.error("upload failed: \(job.error?.localizedDescription ?? "unknown error", privacy: .public)")
            }
        }
        if !finished.isEmpty {
            try await library.performChanges {
                for job in finished {
                    PHAssetResourceUploadJobChangeRequest(for: job)?.acknowledge()
                }
            }
        }
        let requeue = recordResults(succeeded: succeeded, failed: failed)

        // 3. Queue photos/videos added since last time.
        var queue = defaults.stringArray(forKey: SharedConfig.queueKey) ?? []
        queue += requeue
        if defaults.bool(forKey: Self.needsResyncKey) {
            do {
                queue += try await resync(server)
                defaults.set(false, forKey: Self.needsResyncKey)
            } catch {
                log.error("re-sync failed, will try again: \(error.localizedDescription, privacy: .public)")
            }
        }
        guard let added = newAssetIdentifiers() else {
            // History was pruned past our token: save the queue and re-sync next run.
            saveQueue(queue)
            return .processing
        }
        queue += added
        queue = saveQueue(queue)

        // 4. Keep the job queue filled up to the in-flight limit.
        let capacity = max(0, PHAssetResourceUploadJob.jobLimit - jobs(.process).count)
        let batch = Array(queue.prefix(capacity))
        if !batch.isEmpty {
            var uploads: [(URLRequest, PHAssetResource)] = []
            PHAsset.fetchAssets(withLocalIdentifiers: batch, options: nil).enumerateObjects { asset, _, _ in
                guard let resource = asset.backupResource else { return }
                uploads.append((server.putRequest(filename: asset.backupFilename), resource))
            }
            if !uploads.isEmpty {
                // Throws limitExceeded if the system has less room than jobLimit suggests;
                // processJobs() then returns .processing and the batch stays queued.
                try await library.performChanges {
                    for (destination, resource) in uploads {
                        _ = PHAssetResourceUploadJobChangeRequest.creationRequestForJob(
                            destination: destination, resource: resource)
                    }
                }
            }
            queue.removeFirst(batch.count)
            saveQueue(queue)
            log.info("created \(uploads.count) upload job(s), \(queue.count) still queued")
        }

        let resyncPending = defaults.bool(forKey: Self.needsResyncKey)
        return queue.isEmpty && !resyncPending ? .completed : .processing
    }

    private func jobs(_ action: PHAssetResourceUploadJob.Action) -> [PHAssetResourceUploadJob] {
        let result = PHAssetResourceUploadJob.fetchJobs(action: action, options: nil)
        return (0..<result.count).map { result.object(at: $0) }
    }

    /// Removes duplicates and saves the queue.
    @discardableResult
    private func saveQueue(_ queue: [String]) -> [String] {
        var seen = Set<String>()
        let unique = queue.filter { seen.insert($0).inserted }
        defaults.set(unique, forKey: SharedConfig.queueKey)
        return unique
    }

    /// Updates the failure counts and returns the failed assets that should be tried again.
    private func recordResults(succeeded: [String], failed: [String]) -> [String] {
        var counts = defaults.dictionary(forKey: Self.failureCountsKey) as? [String: Int] ?? [:]
        for id in succeeded { counts[id] = nil }
        var requeue: [String] = []
        for id in failed {
            let n = (counts[id] ?? 0) + 1
            if n < Self.maxFailures {
                counts[id] = n
                requeue.append(id)
            } else {
                counts[id] = nil
                log.error("giving up on \(id, privacy: .public) after \(n) failures; Start Backup will retry it")
            }
        }
        defaults.set(counts, forKey: Self.failureCountsKey)
        return requeue
    }

    /// Identifiers of assets inserted since the saved change token, advancing the token.
    /// Nil if the history no longer reaches back to the token: the token is then reset and a
    /// re-sync is flagged for the next run.
    private func newAssetIdentifiers() -> [String]? {
        let current = library.currentChangeToken
        let now = Date()
        guard let since = SharedConfig.changeToken?.token else {
            SharedConfig.changeToken = PHPersistentChangeTokenBox(current)
            defaults.set(now, forKey: SharedConfig.lastSyncDateKey)
            return []
        }

        var ids: [String] = []
        do {
            for change in try library.fetchPersistentChanges(since: since) {
                ids += try change.changeDetails(for: .asset).insertedLocalIdentifiers
            }
        } catch {
            log.error("change history unavailable, will re-sync: \(error.localizedDescription, privacy: .public)")
            SharedConfig.changeToken = PHPersistentChangeTokenBox(current)
            defaults.set(true, forKey: Self.needsResyncKey)
            return nil
        }
        SharedConfig.changeToken = PHPersistentChangeTokenBox(current)
        // While a re-sync is pending, keep the old date so it still covers the gap.
        if !defaults.bool(forKey: Self.needsResyncKey) {
            defaults.set(now, forKey: SharedConfig.lastSyncDateKey)
        }
        return ids
    }

    /// Assets added or changed since a day before the last sync that the server doesn't have.
    /// Imports keep their original creation date but get a new modification date, so both are
    /// checked.
    private func resync(_ server: Server) async throws -> [String] {
        let lastSync = defaults.object(forKey: SharedConfig.lastSyncDateKey) as? Date
            ?? Date(timeIntervalSinceNow: -30 * 86_400)
        let since = lastSync.addingTimeInterval(-86_400) as NSDate
        let options = PHFetchOptions()
        options.predicate = NSPredicate(format: "creationDate >= %@ OR modificationDate >= %@", since, since)

        var candidates: [(id: String, filename: String)] = []
        PHAsset.fetchAssets(with: options).enumerateObjects { asset, _, _ in
            candidates.append((asset.localIdentifier, asset.backupFilename))
        }
        var missing: [String] = []
        for start in stride(from: 0, to: candidates.count, by: 500) {
            let batch = candidates[start..<min(start + 500, candidates.count)]
            let present = try await server.present(batch.map(\.filename))
            missing += batch.filter { !present.contains($0.filename) }.map(\.id)
        }
        log.info("re-sync: \(candidates.count) recent asset(s), \(missing.count) not on the server")
        return missing
    }

    // MARK: - Error classification

    /// Failures worth retrying with the same request: the network, not the server, was the
    /// problem. The system's error uses NSURLErrorDomain codes.
    private static func isTransient(_ error: Error?) -> Bool {
        guard let error = error as NSError?, error.domain == NSURLErrorDomain else { return true }
        let transient: Set<URLError.Code> = [
            .timedOut, .networkConnectionLost, .notConnectedToInternet, .cannotConnectToHost,
            .cannotFindHost, .dnsLookupFailed, .internationalRoamingOff, .dataNotAllowed,
            .callIsActive, .secureConnectionFailed, .backgroundSessionWasDisconnected,
        ]
        return transient.contains(URLError.Code(rawValue: error.code))
    }

    private static func isLimitExceeded(_ error: Error) -> Bool {
        let error = error as NSError
        return error.domain == PHPhotosErrorDomain && error.code == PHPhotosError.Code.limitExceeded.rawValue
    }
}

/// The upload server, as seen from the extension.
private struct Server {
    let base: URL
    let device: String
    let apiKey: String

    private var deviceURL: URL {
        base.appending(component: "files").appending(component: device)
    }

    func putRequest(filename: String) -> URLRequest {
        var request = URLRequest(url: deviceURL.appending(component: filename))
        request.httpMethod = "PUT"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        return request
    }

    /// Which of `filenames` the server already has (`POST /files/<device>`).
    func present(_ filenames: [String]) async throws -> Set<String> {
        var request = URLRequest(url: deviceURL, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(["filenames": filenames])
        let (data, response) = try await URLSession.shared.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else { throw URLError(.badServerResponse) }
        struct Response: Decodable { let present: [String] }
        return Set(try JSONDecoder().decode(Response.self, from: data).present)
    }
}
