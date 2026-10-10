import Combine
import Foundation
import Photos

/// The newest photos and videos in the library, with whether each is on the server.
@MainActor
final class RecentMedia: NSObject, ObservableObject, PHPhotoLibraryChangeObserver {
    enum Status { case uploaded, notUploaded, unknown }

    struct Item: Identifiable {
        let asset: PHAsset
        let filename: String
        var id: String { asset.localIdentifier }
    }

    @Published private(set) var items: [Item] = []
    @Published private(set) var status: [String: Status] = [:]   // by localIdentifier
    @Published private(set) var accessDenied = false
    @Published var errorMessage: String?

    static let limit = 200

    /// Filenames deleted on the phone whose server delete hasn't succeeded yet.
    private let pendingDeletesKey = "pendingServerDeletes"
    private var serverPresent: Set<String>?
    private var observing = false

    /// Asks for photo access if needed, then loads the list and keeps it current.
    func start() async {
        var auth = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        if auth == .notDetermined {
            auth = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        }
        accessDenied = !(auth == .authorized || auth == .limited)
        guard !accessDenied else { return }
        if !observing {
            PHPhotoLibrary.shared().register(self)
            observing = true
        }
        reload()
        await refreshServerStatus()
    }

    nonisolated func photoLibraryDidChange(_ changeInstance: PHChange) {
        Task { @MainActor in self.reload() }
    }

    /// Re-reads the newest assets from the library (no network).
    func reload() {
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        options.fetchLimit = Self.limit
        var items: [Item] = []
        PHAsset.fetchAssets(with: options).enumerateObjects { asset, _, _ in
            items.append(Item(asset: asset, filename: asset.backupFilename))
        }
        self.items = items
        updateStatus()
    }

    /// Asks the server which items it has, and retries any server deletes that failed earlier.
    func refreshServerStatus() async {
        for filename in pendingDeletes {
            if (try? await ServerAPI.delete(filename)) != nil { removePendingDelete(filename) }
        }
        serverPresent = try? await ServerAPI.present(items.map(\.filename))
        updateStatus()
    }

    /// Server answer when there is one; otherwise this app's own record of SFTP uploads.
    func updateStatus() {
        let local = PhotoUploader.uploadedIDs
        var status: [String: Status] = [:]
        for item in items {
            if let serverPresent {
                status[item.id] = serverPresent.contains(item.filename) ? .uploaded : .notUploaded
            } else {
                status[item.id] = local.contains(item.id) ? .uploaded : .unknown
            }
        }
        self.status = status
    }

    /// Deletes from the photo library (iOS asks to confirm; it goes to Recently Deleted and
    /// iCloud Photos), then from the server.
    func delete(_ item: Item) async {
        let id = item.id
        do {
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.deleteAssets(PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil))
            }
        } catch {
            if (error as? PHPhotosError)?.code != .userCancelled {
                errorMessage = "Could not delete \(item.filename): \(error.localizedDescription)"
            }
            return
        }

        PhotoUploader.forgetUploaded(id)
        do {
            try await ServerAPI.delete(item.filename)
            serverPresent?.remove(item.filename)
        } catch {
            addPendingDelete(item.filename)
            errorMessage = "\(item.filename) was deleted from this phone, but not yet from the server "
                + "(\(error.localizedDescription)). It will be retried next time the app can reach the server."
        }
    }

    private var pendingDeletes: [String] {
        UserDefaults.standard.stringArray(forKey: pendingDeletesKey) ?? []
    }

    private func addPendingDelete(_ filename: String) {
        UserDefaults.standard.set(pendingDeletes + [filename], forKey: pendingDeletesKey)
    }

    private func removePendingDelete(_ filename: String) {
        UserDefaults.standard.set(pendingDeletes.filter { $0 != filename }, forKey: pendingDeletesKey)
    }
}
