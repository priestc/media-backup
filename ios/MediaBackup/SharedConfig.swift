import Foundation
import Photos

/// State shared between the app and the background upload extension through the App Group.
/// This file is compiled into both targets.
nonisolated enum SharedConfig {
    static let appGroup = "group.io.github.priestc.MediaBackup"
    static var defaults: UserDefaults { UserDefaults(suiteName: appGroup)! }

    static let apiKeyKey      = "apiKey"
    static let deviceNameKey  = "deviceName"
    static let changeTokenKey = "photoLibraryChangeToken"
    static let queueKey       = "pendingAssetIdentifiers"

    /// Upload server base URL, baked into Info.plist from the BACKGROUND_UPLOAD_URL_BASE build
    /// setting. iOS refuses background uploads to anywhere outside it. Nil until configured.
    static var uploadURLBase: URL? {
        guard let s = Bundle.main.object(forInfoDictionaryKey: "BackgroundUploadURLBase") as? String,
              s.hasPrefix("http"), !s.contains("example") else { return nil }
        return URL(string: s)
    }

    /// Key the server's `media-backup pair` command shows as a QR code; nil until scanned.
    static var apiKey: String? {
        get { defaults.string(forKey: apiKeyKey).flatMap { $0.isEmpty ? nil : $0 } }
        set { defaults.set(newValue, forKey: apiKeyKey) }
    }

    /// Persistent change token marking where the extension last looked for new photos.
    static var changeToken: PHPersistentChangeTokenBox? {
        get {
            guard let data = defaults.data(forKey: changeTokenKey) else { return nil }
            return PHPersistentChangeTokenBox(data: data)
        }
        set { defaults.set(newValue?.data, forKey: changeTokenKey) }
    }
}

/// Archives a PHPersistentChangeToken to Data for UserDefaults.
nonisolated struct PHPersistentChangeTokenBox {
    let token: PHPersistentChangeToken

    init(_ token: PHPersistentChangeToken) { self.token = token }

    init?(data: Data) {
        guard let t = try? NSKeyedUnarchiver.unarchivedObject(ofClass: PHPersistentChangeToken.self, from: data)
        else { return nil }
        token = t
    }

    var data: Data? { try? NSKeyedArchiver.archivedData(withRootObject: token, requiringSecureCoding: true) }
}

nonisolated extension PHAsset {
    /// The resource that gets backed up — the same choice for SFTP, background and HTTPS
    /// uploads, so the server sees one file however it arrives.
    var backupResource: PHAssetResource? {
        let resources = PHAssetResource.assetResources(for: self)
        return resources.first(where: {
            $0.type == .photo || $0.type == .video ||
            $0.type == .fullSizePhoto || $0.type == .fullSizeVideo
        }) ?? resources.first
    }

    /// Filename on the server: `<upload-dir>/<device>/<backupFilename>`.
    var backupFilename: String {
        let resources = PHAssetResource.assetResources(for: self)
        if let name = resources.first?.originalFilename, !name.isEmpty { return name }
        let ext = mediaType == .video ? "mp4" : "jpg"
        return "\(localIdentifier.prefix(8)).\(ext)"
    }
}
