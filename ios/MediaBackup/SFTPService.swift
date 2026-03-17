import Citadel
import Foundation
import NIOCore
import NIOPosix
import NIOSSH

/// Manages a single SSH/SFTP connection for the duration of a backup session.
actor SFTPService {
    private var sshClient: SSHClient?
    private var sftpClient: SFTPClient?

    func connect(host: String, port: Int, username: String) async throws {
        let privateKey = KeyManager.shared.privateKey
        let client = try await SSHClient.connect(
            host: host,
            port: port,
            authenticationMethod: .publicKeyBased(
                username: username,
                privateKey: NIOSSHPrivateKey(ed25519Key: privateKey)
            ),
            hostKeyValidator: .acceptAnything(),   // home NAS — no need for strict validation
            reconnect: .never
        )
        let sftp = try await client.openSFTP()
        self.sshClient = client
        self.sftpClient = sftp
    }

    func disconnect() async {
        try? await sshClient?.close()
        sshClient = nil
        sftpClient = nil
    }

    /// Upload data to a remote path, creating parent directories as needed.
    func upload(data: Data, toPath remotePath: String) async throws {
        guard let sftp = sftpClient else { throw SFTPError.notConnected }

        // Ensure parent directory exists
        let remoteDir = (remotePath as NSString).deletingLastPathComponent
        try await mkdirP(sftp: sftp, path: remoteDir)

        // Write file
        var buffer = ByteBuffer(data: data)
        try await sftp.withFile(filePath: remotePath, flags: [.write, .create, .truncate]) { file in
            try await file.write(buffer)
        }
    }

    /// Check if a remote path already exists.
    func fileExists(atPath path: String) async -> Bool {
        guard let sftp = sftpClient else { return false }
        return (try? await sftp.getAttributes(at: path)) != nil
    }

    // MARK: - Private

    private func mkdirP(sftp: SFTPClient, path: String) async throws {
        var components = path.split(separator: "/", omittingEmptySubsequences: true)
        var current = path.hasPrefix("/") ? "/" : ""
        for part in components {
            current += (current == "/" ? "" : "/") + part
            try? await sftp.createDirectory(atPath: current)
        }
    }

    enum SFTPError: Error {
        case notConnected
    }
}
