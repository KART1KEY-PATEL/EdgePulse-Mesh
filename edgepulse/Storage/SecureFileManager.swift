import Foundation
import CryptoKit
import BitLogger
import CommonCrypto

final class SecureFileManager {
    static let shared = SecureFileManager()
    private let keychain = KeychainManager()
    private let queue = DispatchQueue(label: "chat.edgepulse.filemanager")
    private let fileManager = FileManager.default
    
    struct FileMetadata: Codable {
        let fileId: String
        let originalFileName: String
        let mimeType: String?
        let fileSize: Int64
        let ownerId: String // PeerID of the owner
        let createdAt: Date
        var allowedPeerIds: [String] // Peers who have access
        let isPublic: Bool // If true, anyone can access
    }
    
    struct FileAccessRequest: Codable {
        let requestId: String
        let fileId: String
        let requesterId: String // PeerID requesting access
        let requesterNickname: String
        let timestamp: Date
    }
    
    struct FileAccessResponse: Codable {
        let requestId: String
        let fileId: String
        let granted: Bool
        let encryptedFileKey: Data? // Only if granted
    }
    
    private var fileMetadata: [String: FileMetadata] = [:]
    private var pendingRequests: [String: FileAccessRequest] = [:]
    private var fileKeys: [String: Data] = [:] // In-memory cache of file encryption keys
    
    // MARK: - File Encryption & Storage
    
    /// Encrypts and stores a file with the user's storage password
    func encryptAndStoreFile(_ url: URL, ownerId: String, mimeType: String?, isPublic: Bool = false) throws -> String {
        guard let storagePassword = getStoragePassword() else {
            throw NSError(domain: "SecureFileManager", code: -1, userInfo: [NSLocalizedDescriptionKey: "Storage password not set"])
        }
        
        let fileId = UUID().uuidString
        let originalFileName = url.lastPathComponent
        let fileData = try Data(contentsOf: url)
        
        // Generate a random file-specific encryption key
        var fileKeyData = Data(count: 32)
        let result = fileKeyData.withUnsafeMutableBytes { bytes in
            SecRandomCopyBytes(kSecRandomDefault, 32, bytes.baseAddress!)
        }
        guard result == errSecSuccess else {
            throw NSError(domain: "SecureFileManager", code: -2, userInfo: [NSLocalizedDescriptionKey: "Failed to generate encryption key"])
        }
        
        // Encrypt file with file-specific key
        let fileKey = SymmetricKey(data: fileKeyData)
        let sealedBox = try AES.GCM.seal(fileData, using: fileKey)
        
        // Save encrypted file
        let destinationUrl = try secureFileDirectory().appendingPathComponent(fileId)
        try sealedBox.combined?.write(to: destinationUrl)
        
        // Encrypt the file key with user's storage password
        let passwordKey = try deriveKey(from: storagePassword, salt: "edgepulse.filekey.\(fileId)".data(using: .utf8)!)
        let encryptedFileKey = try AES.GCM.seal(fileKeyData, using: passwordKey)
        
        // Store encrypted file key
        let keyUrl = try secureFileDirectory().appendingPathComponent("\(fileId).key")
        try encryptedFileKey.combined?.write(to: keyUrl)
        
        // Create metadata
        let metadata = FileMetadata(
            fileId: fileId,
            originalFileName: originalFileName,
            mimeType: mimeType,
            fileSize: Int64(fileData.count),
            ownerId: ownerId,
            createdAt: Date(),
            allowedPeerIds: [ownerId], // Owner always has access
            isPublic: isPublic
        )
        
        queue.sync {
            fileMetadata[fileId] = metadata
            fileKeys[fileId] = fileKeyData
        }
        
        // Persist metadata
        try saveMetadata()
        
        SecureLogger.info("Encrypted and stored file \(fileId) (\(originalFileName))", category: .storage)
        return fileId
    }
    
    /// Decrypts and retrieves a file if user has access
    func decryptFile(_ fileId: String, requesterId: String) throws -> (data: Data, metadata: FileMetadata) {
        guard let metadata = queue.sync(execute: { fileMetadata[fileId] }) else {
            throw NSError(domain: "SecureFileManager", code: -3, userInfo: [NSLocalizedDescriptionKey: "File not found"])
        }
        
        // Check access permissions
        guard canAccessFile(fileId, peerId: requesterId) else {
            throw NSError(domain: "SecureFileManager", code: -4, userInfo: [NSLocalizedDescriptionKey: "Access denied"])
        }
        
        // Get file encryption key
        let fileKeyData = try getFileKey(fileId)
        let fileKey = SymmetricKey(data: fileKeyData)
        
        // Read and decrypt file
        let fileUrl = try secureFileDirectory().appendingPathComponent(fileId)
        let encryptedData = try Data(contentsOf: fileUrl)
        let sealedBox = try AES.GCM.SealedBox(combined: encryptedData)
        let decryptedData = try AES.GCM.open(sealedBox, using: fileKey)
        
        SecureLogger.info("Decrypted file \(fileId) for \(requesterId)", category: .storage)
        return (decryptedData, metadata)
    }
    
    // MARK: - Access Control
    
    func canAccessFile(_ fileId: String, peerId: String) -> Bool {
        return queue.sync {
            guard let metadata = fileMetadata[fileId] else { return false }
            return metadata.isPublic || metadata.allowedPeerIds.contains(peerId) || metadata.ownerId == peerId
        }
    }
    
    /// Creates an access request for a file
    func createAccessRequest(forFile fileId: String, requesterId: String, requesterNickname: String) -> FileAccessRequest? {
        return queue.sync {
            guard let metadata = fileMetadata[fileId] else { return nil }
            
            // Don't create request if already has access
            if canAccessFile(fileId, peerId: requesterId) {
                return nil
            }
            
            let request = FileAccessRequest(
                requestId: UUID().uuidString,
                fileId: fileId,
                requesterId: requesterId,
                requesterNickname: requesterNickname,
                timestamp: Date()
            )
            
            pendingRequests[request.requestId] = request
            SecureLogger.info("Created access request \(request.requestId) for file \(fileId)", category: .security)
            return request
        }
    }
    
    /// Gets pending access requests for files owned by this user
    func getPendingRequests(forOwnerId ownerId: String) -> [FileAccessRequest] {
        return queue.sync {
            pendingRequests.values.filter { request in
                guard let metadata = fileMetadata[request.fileId] else { return false }
                return metadata.ownerId == ownerId
            }.sorted { $0.timestamp > $1.timestamp }
        }
    }
    
    /// Grants access to a file for a specific peer
    func grantAccess(requestId: String, ownerId: String) throws -> FileAccessResponse {
        return try queue.sync {
            guard let request = pendingRequests[requestId] else {
                throw NSError(domain: "SecureFileManager", code: -5, userInfo: [NSLocalizedDescriptionKey: "Request not found"])
            }
            
            guard var metadata = fileMetadata[request.fileId] else {
                throw NSError(domain: "SecureFileManager", code: -6, userInfo: [NSLocalizedDescriptionKey: "File not found"])
            }
            
            guard metadata.ownerId == ownerId else {
                throw NSError(domain: "SecureFileManager", code: -7, userInfo: [NSLocalizedDescriptionKey: "Not file owner"])
            }
            
            // Add peer to allowed list
            if !metadata.allowedPeerIds.contains(request.requesterId) {
                metadata.allowedPeerIds.append(request.requesterId)
                fileMetadata[request.fileId] = metadata
            }
            
            // Get file key and encrypt it for the requester
            let fileKeyData = try getFileKey(request.fileId)
            
            // For now, we'll use the same storage password approach
            // In a full implementation, you'd use the requester's public key
            let response = FileAccessResponse(
                requestId: requestId,
                fileId: request.fileId,
                granted: true,
                encryptedFileKey: fileKeyData
            )
            
            // Remove from pending
            pendingRequests.removeValue(forKey: requestId)
            
            // Persist updated metadata
            try saveMetadata()
            
            SecureLogger.info("Granted access to file \(request.fileId) for \(request.requesterId)", category: .security)
            return response
        }
    }
    
    /// Denies access to a file
    func denyAccess(requestId: String, ownerId: String) throws -> FileAccessResponse {
        return try queue.sync {
            guard let request = pendingRequests[requestId] else {
                throw NSError(domain: "SecureFileManager", code: -5, userInfo: [NSLocalizedDescriptionKey: "Request not found"])
            }
            
            guard let metadata = fileMetadata[request.fileId] else {
                throw NSError(domain: "SecureFileManager", code: -6, userInfo: [NSLocalizedDescriptionKey: "File not found"])
            }
            
            guard metadata.ownerId == ownerId else {
                throw NSError(domain: "SecureFileManager", code: -7, userInfo: [NSLocalizedDescriptionKey: "Not file owner"])
            }
            
            let response = FileAccessResponse(
                requestId: requestId,
                fileId: request.fileId,
                granted: false,
                encryptedFileKey: nil
            )
            
            // Remove from pending
            pendingRequests.removeValue(forKey: requestId)
            
            SecureLogger.info("Denied access to file \(request.fileId) for \(request.requesterId)", category: .security)
            return response
        }
    }
    
    /// Handles receiving an access response
    func handleAccessResponse(_ response: FileAccessResponse, forPeerId peerId: String) throws {
        try queue.sync {
            guard response.granted, let encryptedKey = response.encryptedFileKey else {
                SecureLogger.warning("Access denied for file \(response.fileId)", category: .security)
                return
            }
            
            // Store the file key
            fileKeys[response.fileId] = encryptedKey
            
            // Update metadata to include this peer
            if var metadata = fileMetadata[response.fileId] {
                if !metadata.allowedPeerIds.contains(peerId) {
                    metadata.allowedPeerIds.append(peerId)
                    fileMetadata[response.fileId] = metadata
                    try saveMetadata()
                }
            }
            
            SecureLogger.info("Received access grant for file \(response.fileId)", category: .security)
        }
    }
    
    // MARK: - File Management
    
    func getFileMetadata(_ fileId: String) -> FileMetadata? {
        return queue.sync { fileMetadata[fileId] }
    }
    
    func getAllOwnedFiles(ownerId: String) -> [FileMetadata] {
        return queue.sync {
            fileMetadata.values.filter { $0.ownerId == ownerId }.sorted { $0.createdAt > $1.createdAt }
        }
    }
    
    func deleteFile(_ fileId: String, ownerId: String) throws {
        try queue.sync {
            guard let metadata = fileMetadata[fileId] else {
                throw NSError(domain: "SecureFileManager", code: -8, userInfo: [NSLocalizedDescriptionKey: "File not found"])
            }
            
            guard metadata.ownerId == ownerId else {
                throw NSError(domain: "SecureFileManager", code: -9, userInfo: [NSLocalizedDescriptionKey: "Not file owner"])
            }
            
            // Delete encrypted file
            let fileUrl = try secureFileDirectory().appendingPathComponent(fileId)
            try? fileManager.removeItem(at: fileUrl)
            
            // Delete key file
            let keyUrl = try secureFileDirectory().appendingPathComponent("\(fileId).key")
            try? fileManager.removeItem(at: keyUrl)
            
            // Remove metadata
            fileMetadata.removeValue(forKey: fileId)
            fileKeys.removeValue(forKey: fileId)
            
            // Remove any pending requests
            pendingRequests = pendingRequests.filter { $0.value.fileId != fileId }
            
            try saveMetadata()
            
            SecureLogger.info("Deleted file \(fileId)", category: .storage)
        }
    }
    
    // MARK: - Private Helpers
    
    private func getStoragePassword() -> String? {
        return SecureMessageStore.shared.hasActivePassword() ? "temp" : nil
    }
    
    private func getFileKey(_ fileId: String) throws -> Data {
        // Check cache first
        if let cachedKey = queue.sync(execute: { fileKeys[fileId] }) {
            return cachedKey
        }
        
        // Load from disk
        guard let storagePassword = getStoragePassword() else {
            throw NSError(domain: "SecureFileManager", code: -10, userInfo: [NSLocalizedDescriptionKey: "Storage password not available"])
        }
        
        let keyUrl = try secureFileDirectory().appendingPathComponent("\(fileId).key")
        let encryptedKeyData = try Data(contentsOf: keyUrl)
        
        let passwordKey = try deriveKey(from: storagePassword, salt: "edgepulse.filekey.\(fileId)".data(using: .utf8)!)
        let sealedBox = try AES.GCM.SealedBox(combined: encryptedKeyData)
        let fileKeyData = try AES.GCM.open(sealedBox, using: passwordKey)
        
        // Cache it
        queue.sync { fileKeys[fileId] = fileKeyData }
        
        return fileKeyData
    }
    
    private func deriveKey(from password: String, salt: Data) throws -> SymmetricKey {
        guard let passwordData = password.data(using: .utf8) else {
            throw NSError(domain: "SecureFileManager", code: -11, userInfo: [NSLocalizedDescriptionKey: "Invalid password"])
        }
        
        let rounds = 100_000
        var derivedKeyData = Data(count: 32)
        
        let result = derivedKeyData.withUnsafeMutableBytes { derivedKeyBytes in
            salt.withUnsafeBytes { saltBytes in
                passwordData.withUnsafeBytes { passwordBytes in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        passwordBytes.baseAddress?.assumingMemoryBound(to: Int8.self),
                        passwordData.count,
                        saltBytes.baseAddress?.assumingMemoryBound(to: UInt8.self),
                        salt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                        UInt32(rounds),
                        derivedKeyBytes.baseAddress?.assumingMemoryBound(to: UInt8.self),
                        32
                    )
                }
            }
        }
        
        guard result == kCCSuccess else {
            throw NSError(domain: "SecureFileManager", code: -12, userInfo: [NSLocalizedDescriptionKey: "Key derivation failed"])
        }
        
        return SymmetricKey(data: derivedKeyData)
    }
    
    private func saveMetadata() throws {
        let metadataUrl = try secureFileDirectory().appendingPathComponent("metadata.json")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(fileMetadata)
        try data.write(to: metadataUrl)
    }
    
    func loadMetadata() throws {
        let metadataUrl = try secureFileDirectory().appendingPathComponent("metadata.json")
        guard fileManager.fileExists(atPath: metadataUrl.path) else { return }
        
        let data = try Data(contentsOf: metadataUrl)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let loaded = try decoder.decode([String: FileMetadata].self, from: data)
        
        queue.sync {
            fileMetadata = loaded
        }
        
        SecureLogger.info("Loaded \(loaded.count) file metadata entries", category: .storage)
    }
    
    private func secureFileDirectory() throws -> URL {
        let url = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ).appendingPathComponent("securefiles", isDirectory: true)
        
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true
        )
        
        return url
    }
}
