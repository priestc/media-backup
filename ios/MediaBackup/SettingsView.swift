import SwiftUI

struct SettingsView: View {
    @AppStorage("sshLocalHost")    private var localHost    = ""
    @AppStorage("sshTailscaleHost") private var tailscaleHost = ""
    @AppStorage("sshPort")         private var portStr      = "22"
    @AppStorage("sshUsername")     private var username     = ""
    @AppStorage("sshRemotePath")   private var remotePath   = ""
    @Environment(\.dismiss)        private var dismiss

    @State private var testResult: String? = nil
    @State private var isTesting = false
    @State private var keyCopied = false
    @State private var backgroundStatus = ""
    @State private var paired = SharedConfig.apiKey != nil
    @State private var showScanner = false
    @State private var pairingError: String? = nil

    private var publicKey: String { KeyManager.shared.publicKeyString }

    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("Server"),
                        footer: Text("Local is tried first. Tailscale is used as fallback when away from home.")) {
                    TextField("192.168.1.x  (Local)", text: $localHost)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("100.x.x.x  (Tailscale)", text: $tailscaleHost)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("SSH Port", text: $portStr)
                        .keyboardType(.numberPad)
                }

                Section(header: Text("Credentials")) {
                    TextField("Username", text: $username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }

                Section(
                    header: Text("SSH Public Key"),
                    footer: Text("Add this key to ~/.ssh/authorized_keys on your NAS to allow password-free SFTP login (used by Start Backup).")
                ) {
                    Text(publicKey)
                        .font(.system(.caption, design: .monospaced))
                        .lineLimit(3)
                        .foregroundColor(.secondary)

                    Button(keyCopied ? "Copied!" : "Copy Public Key") {
                        UIPasteboard.general.string = publicKey
                        keyCopied = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { keyCopied = false }
                    }
                }

                Section(header: Text("Destination"),
                        footer: Text("Files are stored as: remote-path/device-name/filename")) {
                    TextField("/home/chris/photos", text: $remotePath)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }

                Section(
                    header: Text("Server Pairing"),
                    footer: Text("Run `media-backup pair` on the server and scan the QR code it prints. It fills in the server addresses and port above, and holds the key that lets this app upload, check and delete files over HTTPS.")
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
                    footer: Text("New photos and videos are uploaded by iOS in the background soon after they're taken, over HTTPS to \(SharedConfig.uploadURLBase?.absoluteString ?? "the server URL set in Xcode (BACKGROUND_UPLOAD_URL_BASE)").")
                ) {
                    Text(backgroundStatus)
                        .font(.footnote)
                        .foregroundColor(backgroundStatus.hasPrefix("On") ? .green : .secondary)
                }

                Section {
                    Button(action: testConnection) {
                        if isTesting {
                            HStack { ProgressView(); Text("Testing…").padding(.leading, 8) }
                        } else {
                            Text("Test Connection")
                        }
                    }
                    .disabled(isTesting || username.isEmpty ||
                              (localHost.isEmpty && tailscaleHost.isEmpty))

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

    /// Applies a `media-backup://pair?key=…&local=…&tailscale=…&ssh_port=…` code from
    /// `media-backup pair`: the API key, plus whichever SFTP settings the server could detect.
    private func pair(_ code: String) {
        guard let url = URLComponents(string: code.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.scheme == "media-backup", url.host == "pair" else {
            pairingError = "That isn't a media-backup pairing code. Run `media-backup pair` on the server."
            return
        }
        var params: [String: String] = [:]
        for item in url.queryItems ?? [] {
            if let value = item.value, !value.isEmpty { params[item.name] = value }
        }
        guard let apiKey = params["key"] else {
            pairingError = "The pairing code has no API key."
            return
        }
        SharedConfig.apiKey = apiKey
        if let host = params["local"] { localHost = host }
        if let host = params["tailscale"] { tailscaleHost = host }
        if let port = params["ssh_port"] { portStr = port }
        paired = true
        backgroundStatus = BackgroundUpload.configure()
    }

    private func testConnection() {
        let port = Int(portStr) ?? 22
        isTesting = true
        testResult = nil

        Task {
            let sftp = SFTPService()
            var connectedHost: String? = nil
            for host in [localHost, tailscaleHost] {
                let h = host.trimmingCharacters(in: .whitespaces)
                guard !h.isEmpty else { continue }
                do {
                    try await sftp.connect(host: h, port: port, username: username)
                    connectedHost = h
                    break
                } catch {}
            }
            await sftp.disconnect()

            await MainActor.run {
                isTesting = false
                if let host = connectedHost {
                    testResult = "✓ Connected to \(host)"
                } else {
                    testResult = "Connection failed. Check host, username, and that your public key is in authorized_keys."
                }
            }
        }
    }
}
