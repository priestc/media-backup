import SwiftUI

struct SettingsView: View {
    @AppStorage("sshLocalHost")    private var localHost    = ""
    @AppStorage("sshTailscaleHost") private var tailscaleHost = ""
    @AppStorage("sshPort")         private var portStr      = "22"
    @AppStorage("sshUsername")     private var username     = ""
    @AppStorage("sshPassword")     private var password     = ""
    @AppStorage("sshRemotePath")   private var remotePath   = ""
    @Environment(\.dismiss)        private var dismiss

    @State private var testResult: String? = nil
    @State private var isTesting = false

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
                    SecureField("Password", text: $password)
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
                    .disabled(isTesting || username.isEmpty || password.isEmpty ||
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
                    try await sftp.connect(host: h, port: port, username: username, password: password)
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
                    testResult = "Connection failed. Check host, credentials, and that SSH is enabled."
                }
            }
        }
    }
}
