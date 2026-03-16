import SwiftUI

struct ContentView: View {
    @StateObject private var uploader = PhotoUploader()
    @State private var showSettings = false

    var body: some View {
        NavigationView {
            VStack(spacing: 24) {
                // Status card
                VStack(spacing: 8) {
                    Image(systemName: statusIcon)
                        .font(.system(size: 48))
                        .foregroundColor(statusColor)
                    Text(uploader.statusMessage)
                        .multilineTextAlignment(.center)
                        .font(.body)
                        .foregroundColor(.secondary)
                        .padding(.horizontal)
                }
                .padding(.top, 32)

                // Progress bar (visible during upload)
                if uploader.isRunning && uploader.totalPending > 0 {
                    VStack(spacing: 4) {
                        ProgressView(value: Double(uploader.uploadedCount),
                                     total: Double(uploader.totalPending))
                            .padding(.horizontal)
                        Text("\(uploader.uploadedCount) / \(uploader.totalPending)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        if !uploader.currentFile.isEmpty {
                            Text(uploader.currentFile)
                                .font(.caption2)
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .padding(.horizontal)
                        }
                    }
                }

                Spacer()

                // Start / Stop button
                Button(action: toggleBackup) {
                    Label(
                        uploader.isRunning ? "Stop" : "Start Backup",
                        systemImage: uploader.isRunning ? "stop.fill" : "arrow.up.to.cloud.fill"
                    )
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(uploader.isRunning ? Color.red : Color.blue)
                    .foregroundColor(.white)
                    .cornerRadius(12)
                    .padding(.horizontal)
                }

                Spacer().frame(height: 16)
            }
            .navigationTitle("Media Backup")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { showSettings = true } label: {
                        Image(systemName: "gear")
                    }
                }
            }
            .sheet(isPresented: $showSettings) {
                SettingsView()
            }
        }
    }

    private var statusIcon: String {
        if uploader.isRunning { return "arrow.up.circle.fill" }
        if uploader.statusMessage.hasPrefix("✓") { return "checkmark.circle.fill" }
        if uploader.statusMessage.lowercased().contains("error") ||
           uploader.statusMessage.lowercased().contains("denied") ||
           uploader.statusMessage.lowercased().contains("could not") { return "exclamationmark.circle.fill" }
        return "photo.on.rectangle.angled"
    }

    private var statusColor: Color {
        if uploader.isRunning { return .blue }
        if uploader.statusMessage.hasPrefix("✓") { return .green }
        if uploader.statusMessage.lowercased().contains("error") ||
           uploader.statusMessage.lowercased().contains("denied") ||
           uploader.statusMessage.lowercased().contains("could not") { return .red }
        return .secondary
    }

    private func toggleBackup() {
        if uploader.isRunning {
            uploader.stop()
        } else {
            let localURL     = UserDefaults.standard.string(forKey: "localURL") ?? ""
            let tailscaleURL = UserDefaults.standard.string(forKey: "tailscaleURL") ?? ""
            let apiKey       = UserDefaults.standard.string(forKey: "apiKey") ?? ""
            Task { await uploader.startBackup(localURL: localURL, tailscaleURL: tailscaleURL, apiKey: apiKey) }
        }
    }
}
