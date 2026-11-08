import SwiftUI

struct SettingsView: View {
    /// Owned by ContentView so a backup keeps reporting progress after Settings closes.
    @ObservedObject var uploader: PhotoUploader
    @Environment(\.dismiss) private var dismiss

    @State private var testResult: String? = nil
    @State private var isTesting = false
    @State private var backgroundStatus = ""
    @State private var paired = SharedConfig.apiKey != nil
    @State private var showScanner = false
    @State private var pairingError: String? = nil

    private var serverURL: String {
        SharedConfig.uploadURLBase?.absoluteString ?? "the server URL set in Xcode (BACKGROUND_UPLOAD_URL_BASE)"
    }

    var body: some View {
        NavigationView {
            Form {
                Section(
                    header: Text("Server Pairing"),
                    footer: Text("Run `media-backup pair` on the server and scan the QR code it prints. It holds the key that lets this app upload, check and delete files at \(serverURL).")
                ) {
                    Label(paired ? "Paired" : "Not paired",
                          systemImage: paired ? "checkmark.seal.fill" : "exclamationmark.triangle")
                        .foregroundColor(paired ? .green : .orange)
                    Button(paired ? "Scan New Pairing QR Code" : "Scan Pairing QR Code") {
                        pairingError = nil
                        showScanner = true
                    }
                    if let pairingError {
                        Text(pairingError)
                            .font(.footnote)
                            .foregroundColor(.red)
                    }
                }

                Section(
                    header: Text("Automatic Upload"),
                    footer: Text("New photos and videos are uploaded by iOS in the background soon after they're taken.")
                ) {
                    Text(backgroundStatus)
                        .font(.footnote)
                        .foregroundColor(backgroundStatus.hasPrefix("On") ? .green : .secondary)
                }

                Section(
                    header: Text("Full Backup"),
                    footer: Text("Uploads every photo and video the server doesn't have yet, such as ones taken before automatic upload was on, or any it missed. Keep the app open while it runs.")
                ) {
                    BackupProgress(uploader: uploader)
                    Button(role: uploader.isRunning ? .destructive : nil, action: toggleBackup) {
                        Label(uploader.isRunning ? "Stop" : "Start Backup",
                              systemImage: uploader.isRunning ? "stop.fill" : "arrow.up.to.cloud.fill")
                    }
                    .disabled(!paired && !uploader.isRunning)
                }

                Section(
                    header: Text("Local Sync"),
                    footer: Text("For big catch-ups at home, like lots of videos: uploads everything the server doesn't have straight over the home Wi-Fi instead of through flightlogg.in or Tailscale. The screen stays on until it finishes; Stop above ends it.")
                ) {
                    Button {
                        Task { await uploader.startBackup(local: true) }
                    } label: {
                        Label("Start Local Sync", systemImage: "wifi")
                    }
                    .disabled(!paired || uploader.isRunning)
                }

                Section {
                    Button(action: testConnection) {
                        if isTesting {
                            HStack { ProgressView(); Text("Testing…").padding(.leading, 8) }
                        } else {
                            Text("Test Connection")
                        }
                    }
                    .disabled(isTesting || !paired)

                    if let result = testResult {
                        Text(result)
                            .font(.footnote)
                            .foregroundColor(result.hasPrefix("✓") ? .green : .red)
                    }
                }
            }
            .navigationTitle("Settings")
            .onAppear { backgroundStatus = BackgroundUpload.configure() }
            .sheet(isPresented: $showScanner) {
                QRScannerSheet(onScanned: pair)
            }
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func toggleBackup() {
        if uploader.isRunning {
            uploader.stop()
        } else {
            Task {
                await uploader.startBackup()
                // Photo access may have just been granted
                backgroundStatus = BackgroundUpload.configure()
            }
        }
    }

    /// Applies a `media-backup://pair?key=…` code from `media-backup pair`.
    private func pair(_ code: String) {
        guard let url = URLComponents(string: code.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.scheme == "media-backup", url.host == "pair" else {
            pairingError = "That isn't a media-backup pairing code. Run `media-backup pair` on the server."
            return
        }
        guard let apiKey = url.queryItems?.first(where: { $0.name == "key" })?.value, !apiKey.isEmpty else {
            pairingError = "The pairing code has no API key."
            return
        }
        SharedConfig.apiKey = apiKey
        paired = true
        testResult = nil
        backgroundStatus = BackgroundUpload.configure()
    }

    private func testConnection() {
        isTesting = true
        testResult = nil
        Task {
            guard let apiKey = SharedConfig.apiKey, !SharedConfig.uploadURLBases.isEmpty else {
                testResult = "Not set up: pair with the server and set BACKGROUND_UPLOAD_URL_BASE."
                isTesting = false
                return
            }
            // Check every server so a broken fallback shows up before it's needed.
            var lines: [String] = []
            for base in SharedConfig.uploadURLBases {
                let status = await SharedConfig.probe(base, device: UIDevice.current.name, apiKey: apiKey)
                lines.append(Self.describe(base, status: status))
            }
            if let active = await ServerAPI.selectServer() {
                lines.append("Uploading via \(active.host() ?? active.absoluteString).")
            }
            testResult = lines.joined(separator: "\n")
            isTesting = false
        }
    }

    private static func describe(_ base: URL, status: Int?) -> String {
        let host = base.host() ?? base.absoluteString
        switch status {
        case let code? where (200..<300).contains(code):
            return "✓ \(host)"
        case 401?:
            return "✗ \(host): the server rejected the key. Run `media-backup pair` and scan the code again."
        case let code? where [502, 503, 504].contains(code):
            return "✗ \(host): the proxy answered but tank2 isn't connected to it (HTTP \(code))."
        case let code?:
            return "✗ \(host): HTTP \(code)"
        case nil:
            return host.hasSuffix(".ts.net")
                ? "✗ \(host): not reachable. Is Tailscale on?"
                : "✗ \(host): not reachable."
        }
    }
}
