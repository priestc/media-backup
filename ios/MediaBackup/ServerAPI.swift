import Foundation
import UIKit

/// HTTPS calls to the upload server (`media-backup serve`) at BACKGROUND_UPLOAD_URL_BASE,
/// authenticated with the API key scanned from `media-backup pair`.
enum ServerAPI {
    enum APIError: LocalizedError {
        case notConfigured
        case notPaired
        case badStatus(Int)

        var errorDescription: String? {
            switch self {
            case .notConfigured: return "No server URL (BACKGROUND_UPLOAD_URL_BASE) is set."
            case .notPaired: return "Not paired with the server. Scan its QR code in Settings."
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

    /// Uploads a file (`PUT /files/<device>/<filename>`, as the background uploader does).
    /// The server skips it if it already has that file.
    static func upload(_ file: URL, as filename: String) async throws {
        var request = try request(path: [filename])
        request.httpMethod = "PUT"
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        let (_, response) = try await URLSession.shared.upload(for: request, fromFile: file)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else { throw APIError.badStatus(code) }
    }

    /// Deletes a file from the server. Succeeds if it was already gone.
    static func delete(_ filename: String) async throws {
        var request = try request(path: [filename])
        request.httpMethod = "DELETE"
        _ = try await send(request)
    }

    private static func request(path: [String]) throws -> URLRequest {
        guard var url = SharedConfig.uploadURLBase else { throw APIError.notConfigured }
        guard let apiKey = SharedConfig.apiKey else { throw APIError.notPaired }
        url = url.appending(component: "files").appending(component: UIDevice.current.name)
        for component in path { url = url.appending(component: component) }
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        return request
    }

    private static func send(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await URLSession.shared.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else { throw APIError.badStatus(code) }
        return data
    }
}
