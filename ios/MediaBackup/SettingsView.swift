import SwiftUI

struct SettingsView: View {
    @AppStorage("localURL")     private var localURL     = ""
    @AppStorage("tailscaleURL") private var tailscaleURL = ""
    @AppStorage("apiKey")       private var apiKey       = ""
    @Environment(\.dismiss)     private var dismiss

    @State private var testResult: String? = nil
    @State private var isTesting = false
    @State private var showScanner = false

    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("Server"),
                        footer: Text("Local is tried first. Tailscale is used as fallback when not on home WiFi.")) {
                    TextField("192.168.1.x:8765  (Local)", text: $localURL)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("100.x.x.x:8765  (Tailscale)", text: $tailscaleURL)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }

                Section(header: Text("Authentication")) {
                    HStack {
                        TextField("API Key", text: $apiKey)
                            .font(.system(.body, design: .monospaced))
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        Button {
                            showScanner = true
                        } label: {
                            Image(systemName: "qrcode.viewfinder")
                                .font(.title2)
                        }
                    }
                }

                Section {
                    Button(action: testConnection) {
                        if isTesting {
                            HStack { ProgressView(); Text("Testing…").padding(.leading, 8) }
                        } else {
                            Text("Test Connection")
                        }
                    }
                    .disabled(isTesting || (localURL.isEmpty && tailscaleURL.isEmpty) || apiKey.isEmpty)

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
            .sheet(isPresented: $showScanner) {
                QRScannerSheet { scanned in
                    apiKey = scanned
                }
            }
        }
    }

    private func normalizeURL(_ raw: String) -> String? {
        var s = raw.trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty else { return nil }
        if !s.hasPrefix("http") { s = "http://" + s }
        if s.hasSuffix("/") { s = String(s.dropLast()) }
        return s
    }

    private func testConnection() {
        let candidates = [localURL, tailscaleURL].compactMap { normalizeURL($0) }
        guard !candidates.isEmpty else { return }

        isTesting = true
        testResult = nil

        let group = DispatchGroup()
        var firstSuccess: String? = nil
        let lock = NSLock()

        for base in candidates {
            guard let url = URL(string: "\(base)/status") else { continue }
            var req = URLRequest(url: url, timeoutInterval: 8)
            req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

            group.enter()
            URLSession.shared.dataTask(with: req) { data, response, _ in
                if let http = response as? HTTPURLResponse, http.statusCode == 200,
                   let data, let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    lock.lock()
                    if firstSuccess == nil {
                        let files = json["files"] as? Int ?? 0
                        let mb    = json["size_mb"] as? Double ?? 0
                        firstSuccess = "✓ Connected via \(base)\n\(files) files stored (\(mb, specifier: "%.1f") MB)"
                    }
                    lock.unlock()
                }
                group.leave()
            }.resume()
        }

        group.notify(queue: .main) {
            isTesting = false
            testResult = firstSuccess ?? "Could not reach any server. Check URLs and API key."
        }
    }
}

extension String.StringInterpolation {
    mutating func appendInterpolation(_ value: Double, specifier: String) {
        appendLiteral(String(format: specifier, value))
    }
}
