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
            do {
                _ = try await ServerAPI.present([])
                testResult = "✓ Connected to \(serverURL)"
            } catch ServerAPI.APIError.badStatus(401) {
                testResult = "The server rejected the key. Run `media-backup pair` and scan the code again."
            } catch {
                testResult = "Could not reach \(serverURL): \(error.localizedDescription) Is Tailscale on?"
            }
            isTesting = false
        }
    }
}
