import SwiftUI
import VisionKit

struct QRScannerView: UIViewControllerRepresentable {
    let onScanned: (String) -> Void
    let onDismiss: () -> Void

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(
            recognizedDataTypes: [.barcode(symbologies: [.qr])],
            isHighlightingEnabled: true
        )
        scanner.delegate = context.coordinator
        try? scanner.startScanning()
        return scanner
    }

    func updateUIViewController(_ uiViewController: DataScannerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let parent: QRScannerView
        init(_ parent: QRScannerView) { self.parent = parent }

        func dataScanner(_ dataScanner: DataScannerViewController,
                         didTapOn item: RecognizedItem) {
            if case .barcode(let barcode) = item, let value = barcode.payloadStringValue {
                parent.onScanned(value)
            }
        }
    }
}

// Wrapper that also handles the availability check
struct QRScannerSheet: View {
    let onScanned: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            Group {
                if DataScannerViewController.isSupported && DataScannerViewController.isAvailable {
                    QRScannerView(
                        onScanned: { value in
                            onScanned(value)
                            dismiss()
                        },
                        onDismiss: { dismiss() }
                    )
                } else {
                    ContentUnavailableView(
                        "Camera Unavailable",
                        systemImage: "camera.slash",
                        description: Text("QR scanning is not available on this device.")
                    )
                }
            }
            .navigationTitle("Scan API Key")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}
