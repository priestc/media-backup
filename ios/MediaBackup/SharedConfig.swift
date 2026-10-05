import Foundation
import Photos

/// State shared between the app and the background upload extension through the App Group.
/// This file is compiled into both targets.
nonisolated enum SharedConfig {
    static let appGroup = "group.io.github.priestc.MediaBackup"
    static var defaults: UserDefaults { UserDefaults(suiteName: appGroup)! }

    static let publicKeyKey   = "sshPublicKey"
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
