import Photos
import UIKit

/// Turns on iOS's Photos background upload extension, which uploads each new photo or
/// video soon after it's taken — even when the app isn't running (iOS 27+).
enum BackgroundUpload {
    /// Shares what the extension needs and enables it. Returns a status line for display.
    @discardableResult
    static func configure() -> String {
        let defaults = SharedConfig.defaults
        defaults.set(KeyManager.shared.publicKeyString, forKey: SharedConfig.publicKeyKey)
        defaults.set(UIDevice.current.name, forKey: SharedConfig.deviceNameKey)

        guard #available(iOS 27, *) else { return "Requires iOS 27 or later" }
        guard SharedConfig.uploadURLBase != nil else {
            return "Off — set BACKGROUND_UPLOAD_URL_BASE in the Xcode project"
        }
        guard PHPhotoLibrary.authorizationStatus(for: .readWrite) == .authorized else {
            return "Needs full photo library access"
        }

        let library = PHPhotoLibrary.shared()
        // Start from "now": older photos are covered by Start Backup.
        if SharedConfig.changeToken == nil {
            SharedConfig.changeToken = PHPersistentChangeTokenBox(library.currentChangeToken)
        }
        do {
            if !library.uploadJobExtensionEnabled {
                try library.enableUploadJobExtension(with: nil)
            }
            return "On — new photos and videos upload automatically"
        } catch {
            return "Error: \(error.localizedDescription)"
        }
    }
}
