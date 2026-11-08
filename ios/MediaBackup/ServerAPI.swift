import Foundation
import UIKit

/// HTTPS calls to the upload server (`media-backup serve`) at BACKGROUND_UPLOAD_URL_BASE,
/// authenticated with the API key scanned from `media-backup pair`.
enum ServerAPI {
    enum APIError: LocalizedError {
        case notConfigured
        case notPaired
        case badStatus(Int)
        case notOnLocalNetwork

        var errorDescription: String? {
            switch self {
            case .notConfigured: return "No server URL (BACKGROUND_UPLOAD_URL_BASE) is set."
            case .notPaired: return "Not paired with the server. Scan its QR code in Settings."
            case .badStatus(let code): return "The server returned HTTP \(code)."
            case .notOnLocalNetwork:
                return "The server isn't reachable on this network. Join the home Wi-Fi and try again "
                    + "(and allow Local Network access in Settings → Privacy if iOS asked)."
            }
        }
    }

    /// While set (during Local Sync), every call goes straight to the server's LAN address with
    /// a short-lived token instead of over HTTPS with the API key, and there is no failover.
    private static var localSession: (base: URL, token: String)?

    /// Asks the server over HTTPS for its LAN address and a Local Sync token, then checks that
    /// address answers from here. Returns the LAN URL now in use.
    static func startLocalSession() async throws -> URL {
        localSession = nil
        struct Offer: Decodable { let urls: [String]; let token: String }
        let offer: Offer = try await withFailover { base in
            guard let apiKey = SharedConfig.apiKey else { throw APIError.notPaired }
            var request = URLRequest(url: base.appending(component: "local-sync"), timeoutInterval: 15)
            request.httpMethod = "POST"
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            return try JSONDecoder().decode(Offer.self, from: try await send(request))
        }
        for case let url? in offer.urls.map(URL.init(string:)) {
            let status = await SharedConfig.probe(url, device: UIDevice.current.name, apiKey: offer.token)
            if let status, (200..<300).contains(status) {
                localSession = (url, offer.token)
                return url
            }
        }
        throw APIError.notOnLocalNetwork
    }

    static func endLocalSession() { localSession = nil }

    /// Which of `filenames` the server has stored for this device.
    static func present(_ filenames: [String]) async throws -> Set<String> {
        try await withFailover { base in
            var request = try request(base, path: [])
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(["filenames": filenames])
            let data = try await send(request)
            struct Response: Decodable { let present: [String] }
            return Set(try JSONDecoder().decode(Response.self, from: data).present)
        }
    }

    /// Uploads a file (`PUT /files/<device>/<filename>`, as the background uploader does).
    /// The server skips it if it already has that file.
    static func upload(_ file: URL, as filename: String) async throws {
        try await withFailover { base in
            var request = try request(base, path: [filename])
            request.httpMethod = "PUT"
            request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
            let (_, response) = try await URLSession.shared.upload(for: request, fromFile: file)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard (200..<300).contains(code) else { throw APIError.badStatus(code) }
        }
    }

    /// Deletes a file from the server. Succeeds if it was already gone.
    static func delete(_ filename: String) async throws {
        try await withFailover { base in
            var request = try request(base, path: [filename])
            request.httpMethod = "DELETE"
            _ = try await send(request)
        }
    }

    /// Picks the preferred server that answers (flightlogg.in, else Tailscale). Nil if none does.
    @discardableResult
    static func selectServer() async -> URL? {
        guard let apiKey = SharedConfig.apiKey else { return nil }
        return await SharedConfig.findReachableBase(device: UIDevice.current.name, apiKey: apiKey)
    }

    /// Runs `operation` against the active server. If that server can't be reached, switches
    /// to another one that answers and runs `operation` once more there.
    private static func withFailover<T>(_ operation: (URL) async throws -> T) async throws -> T {
        if let localSession { return try await operation(localSession.base) }
        guard let base = SharedConfig.uploadURLBase else { throw APIError.notConfigured }
        do {
            return try await operation(base)
        } catch where isUnreachable(error) {
            guard let other = await selectServer(), other != base else { throw error }
            return try await operation(other)
        }
    }

    /// The server didn't answer, or the flightlogg.in proxy answered without tank2 behind it.
    private static func isUnreachable(_ error: Error) -> Bool {
        if error is URLError { return true }
        if case APIError.badStatus(let code) = error { return [502, 503, 504].contains(code) }
        return false
    }

    private static func request(_ base: URL, path: [String]) throws -> URLRequest {
        guard let apiKey = localSession?.token ?? SharedConfig.apiKey else { throw APIError.notPaired }
        var url = base.appending(component: "files").appending(component: UIDevice.current.name)
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
