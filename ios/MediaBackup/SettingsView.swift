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
                    footer: Text("Add this key to ~/.ssh/authorized_keys on your NAS to allow password-free login.")
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
                        footer: Text("Files are stored as: remote-path/device-name/YYYY/MM/DD/filename")) {
                    TextField("/home/chris/photos", text: $remotePath)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
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
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
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
