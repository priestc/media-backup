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
    /// When the change token was last advanced; a re-sync after the token expires looks back
    /// to here.
    static let lastSyncDateKey = "lastSyncDate"

    /// Which of `uploadURLBases` last answered; shared so the app and extension agree.
    static let activeURLBaseKey = "activeURLBase"

    /// Upload server base URLs in order of preference, baked into Info.plist from the
    /// BACKGROUND_UPLOAD_URL_BASE (primary: the public proxy on flightlogg.in) and
    /// BACKGROUND_UPLOAD_FALLBACK_URL_BASE (Tailscale) build settings. Empty until configured.
    static var uploadURLBases: [URL] {
        ["BackgroundUploadURLBase", "BackgroundUploadFallbackURLBase"].compactMap { key in
            guard let s = Bundle.main.object(forInfoDictionaryKey: key) as? String,
                  s.hasPrefix("http"), !s.contains("example") else { return nil }
            return URL(string: s)
        }
    }

    /// The base URL to use now: the one that last answered, else the primary. Nil until configured.
    static var uploadURLBase: URL? {
        let bases = uploadURLBases
        if let saved = defaults.string(forKey: activeURLBaseKey),
           let base = bases.first(where: { $0.absoluteString == saved }) {
            return base
        }
        return bases.first
    }

    /// Tries each base URL in order of preference and makes the first that answers the active
    /// one. Nil (and the active one is left alone) if none answers.
    static func findReachableBase(device: String, apiKey: String) async -> URL? {
        for base in uploadURLBases {
            if isReachable(await probe(base, device: device, apiKey: apiKey)) {
                defaults.set(base.absoluteString, forKey: activeURLBaseKey)
                return base
            }
        }
        return nil
    }

    /// HTTP status of an authenticated no-op request (`POST /files/<device>` with no
    /// filenames) to `base`, or nil if nothing answered.
    static func probe(_ base: URL, device: String, apiKey: String) async -> Int? {
        var request = URLRequest(url: base.appending(component: "files").appending(component: device),
                                 timeoutInterval: 10)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(#"{"filenames":[]}"#.utf8)
        guard let (_, response) = try? await URLSession.shared.data(for: request) else { return nil }
        return (response as? HTTPURLResponse)?.statusCode
    }

    /// Whether a probe status means the media-backup server itself answered. A 502/503/504
    /// is the flightlogg.in proxy answering while tank2's tunnel to it is down.
    static func isReachable(_ status: Int?) -> Bool {
        guard let status else { return false }
        return (200..<300).contains(status) || status == 401
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
