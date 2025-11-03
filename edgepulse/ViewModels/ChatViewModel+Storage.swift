//
// ChatViewModel+Storage.swift
// edgepulse
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Foundation
import BitLogger

/// Extension to ChatViewModel for secure storage integration
extension ChatViewModel {
    
    // MARK: - Message Storage
    
    /// Automatically saves a message to encrypted storage
    func saveMessageToStorage(_ message: EdgepulseMessage) {
        guard SecureMessageStore.shared.hasActivePassword() else {
            SecureLogger.warning("Cannot save message - no active password", category: .storage)
            return
        }
        
        let chatId = getChatId(for: message)
        SecureMessageStore.shared.storeMessage(message, forChat: chatId)
    }
    
    /// Saves multiple messages to encrypted storage
    func saveMessagesToStorage(_ messages: [EdgepulseMessage], forChatId chatId: String) {
        guard SecureMessageStore.shared.hasActivePassword() else {
            SecureLogger.warning("Cannot save messages - no active password", category: .storage)
            return
        }
        
        SecureMessageStore.shared.storeMessages(messages, forChat: chatId)
    }
    
    /// Loads stored messages for a chat
    func loadStoredMessages(forChatId chatId: String) -> [EdgepulseMessage] {
        guard SecureMessageStore.shared.hasActivePassword() else {
            SecureLogger.warning("Cannot load messages - no active password", category: .storage)
            return []
        }
        
        return SecureMessageStore.shared.loadMessages(forChat: chatId)
    }
    
    /// Loads all stored messages on app launch
    @MainActor
    func loadAllStoredMessages() {
        guard SecureMessageStore.shared.hasActivePassword() else {
            SecureLogger.info("Skipping message load - no active password", category: .storage)
            return
        }
        
        let chatIds = SecureMessageStore.shared.getAllChatIds()
        SecureLogger.info("Loading messages from \(chatIds.count) chats", category: .storage)
        
        for chatId in chatIds {
            let storedMessages = SecureMessageStore.shared.loadMessages(forChat: chatId)
            
            if chatId == "public" || chatId == "mesh" {
                // Load public messages
                let newMessages = storedMessages.filter { stored in
                    !self.messages.contains { $0.id == stored.id }
                }
                if !newMessages.isEmpty {
                    self.messages.append(contentsOf: newMessages)
                    SecureLogger.info("Loaded \(newMessages.count) public messages", category: .storage)
                }
            } else {
                // Load private chat messages
                // Assuming chatId is the peer ID
                let peerId = PeerID(str: chatId)
                let existingMessages = self.privateChats[peerId] ?? []
                let newMessages = storedMessages.filter { stored in
                    !existingMessages.contains { $0.id == stored.id }
                }
                if !newMessages.isEmpty {
                    self.privateChats[peerId] = existingMessages + newMessages
                    SecureLogger.info("Loaded \(newMessages.count) messages for peer \(chatId)", category: .storage)
                }
            }
        }
    }
    
    // MARK: - File Handling
    
    /// Encrypts and stores a file, returns file ID
    func encryptAndStoreFile(_ fileURL: URL, mimeType: String?, isPublic: Bool = false) throws -> String {
        guard SecureMessageStore.shared.hasActivePassword() else {
            throw NSError(domain: "ChatViewModel", code: -1, userInfo: [NSLocalizedDescriptionKey: "Storage password not set"])
        }
        
        let ownerId = self.meshService.myPeerID.id
        let fileId = try SecureFileManager.shared.encryptAndStoreFile(
            fileURL,
            ownerId: ownerId,
            mimeType: mimeType,
            isPublic: isPublic
        )
        
        SecureLogger.info("Encrypted and stored file: \(fileId)", category: .storage)
        return fileId
    }
    
    /// Attempts to decrypt a file, returns data if accessible
    func decryptFile(_ fileId: String) throws -> (data: Data, metadata: SecureFileManager.FileMetadata) {
        guard SecureMessageStore.shared.hasActivePassword() else {
            throw NSError(domain: "ChatViewModel", code: -2, userInfo: [NSLocalizedDescriptionKey: "Storage password not set"])
        }
        
        let requesterId = self.meshService.myPeerID.id
        return try SecureFileManager.shared.decryptFile(fileId, requesterId: requesterId)
    }
    
    /// Requests access to a file
    func requestFileAccess(_ fileId: String) -> SecureFileManager.FileAccessRequest? {
        let requesterId = self.meshService.myPeerID.id
        return SecureFileManager.shared.createAccessRequest(
            forFile: fileId,
            requesterId: requesterId,
            requesterNickname: self.nickname
        )
    }
    
    /// Handles receiving a file access request
    func handleFileAccessRequest(_ request: SecureFileManager.FileAccessRequest) {
        // Store the request for UI to display
        // This could be added to a @Published property for UI updates
        SecureLogger.info("Received file access request from \(request.requesterNickname)", category: .security)
        
        // TODO: Add to pending requests list for UI
        // self.pendingFileAccessRequests.append(request)
    }
    
    /// Grants access to a file
    func grantFileAccess(requestId: String) throws -> SecureFileManager.FileAccessResponse {
        let ownerId = self.meshService.myPeerID.id
        let response = try SecureFileManager.shared.grantAccess(requestId: requestId, ownerId: ownerId)
        
        SecureLogger.info("Granted file access for request \(requestId)", category: .security)
        
        // TODO: Send response via mesh network
        // sendFileAccessResponse(response, to: requester)
        
        return response
    }
    
    /// Denies access to a file
    func denyFileAccess(requestId: String) throws -> SecureFileManager.FileAccessResponse {
        let ownerId = self.meshService.myPeerID.id
        let response = try SecureFileManager.shared.denyAccess(requestId: requestId, ownerId: ownerId)
        
        SecureLogger.info("Denied file access for request \(requestId)", category: .security)
        
        // TODO: Send response via mesh network
        // sendFileAccessResponse(response, to: requester)
        
        return response
    }
    
    /// Handles receiving a file access response
    func handleFileAccessResponse(_ response: SecureFileManager.FileAccessResponse) throws {
        let peerId = self.meshService.myPeerID.id
        try SecureFileManager.shared.handleAccessResponse(response, forPeerId: peerId)
        
        if response.granted {
            SecureLogger.info("Received access grant for file \(response.fileId)", category: .security)
            // TODO: Notify UI that file is now accessible
        } else {
            SecureLogger.warning("Access denied for file \(response.fileId)", category: .security)
            // TODO: Notify UI of denial
        }
    }
    
    // MARK: - Helpers
    
    /// Determines the chat ID for a message
    private func getChatId(for message: EdgepulseMessage) -> String {
        if message.isPrivate {
            // Use sender's peer ID for private messages
            return message.senderPeerID?.id ?? "unknown"
        } else {
            // Use "public" or "mesh" for broadcast messages
            return "public"
        }
    }
    
    /// Gets pending file access requests for this user
    func getPendingFileAccessRequests() -> [SecureFileManager.FileAccessRequest] {
        let ownerId = self.meshService.myPeerID.id
        return SecureFileManager.shared.getPendingRequests(forOwnerId: ownerId)
    }
    
    /// Gets all files owned by this user
    func getOwnedFiles() -> [SecureFileManager.FileMetadata] {
        let ownerId = self.meshService.myPeerID.id
        return SecureFileManager.shared.getAllOwnedFiles(ownerId: ownerId)
    }
    
    /// Deletes a file
    func deleteFile(_ fileId: String) throws {
        let ownerId = self.meshService.myPeerID.id
        try SecureFileManager.shared.deleteFile(fileId, ownerId: ownerId)
        SecureLogger.info("Deleted file \(fileId)", category: .storage)
    }
}

