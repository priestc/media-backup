import Foundation
import UIKit

/// HTTPS calls to the upload server (`media-backup serve`) at BACKGROUND_UPLOAD_URL_BASE,
/// authenticated with this device's SSH public key.
enum ServerAPI {
    enum APIError: LocalizedError {
        case notConfigured
        case badStatus(Int)

        var errorDescription: String? {
            switch self {
            case .notConfigured: return "No server URL (BACKGROUND_UPLOAD_URL_BASE) is set."
            case .badStatus(let code): return "The server returned HTTP \(code)."
            }
        }
    }

    /// Which of `filenames` the server has stored for this device.
    static func present(_ filenames: [String]) async throws -> Set<String> {
        var request = try request(path: [])
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(["filenames": filenames])
        let data = try await send(request)
        struct Response: Decodable { let present: [String] }
        return Set(try JSONDecoder().decode(Response.self, from: data).present)
    }

    /// Deletes a file from the server. Succeeds if it was already gone.
    static func delete(_ filename: String) async throws {
        var request = try request(path: [filename])
        request.httpMethod = "DELETE"
        _ = try await send(request)
    }

    private static func request(path: [String]) throws -> URLRequest {
        guard var url = SharedConfig.uploadURLBase else { throw APIError.notConfigured }
        url = url.appending(component: "files").appending(component: UIDevice.current.name)
        for component in path { url = url.appending(component: component) }
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.setValue("Bearer \(KeyManager.shared.publicKeyString)", forHTTPHeaderField: "Authorization")
        return request
    }

    private static func send(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await URLSession.shared.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else { throw APIError.badStatus(code) }
        return data
    }
}
