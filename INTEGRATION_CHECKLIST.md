# Integration Checklist for Secure Storage

## ✅ Completed Components

### Core Storage System
- [x] **SecureMessageStore** - Encrypted message storage with PBKDF2 key derivation
- [x] **SecureFileManager** - File encryption, access control, and metadata management
- [x] **EdgepulseMessage.FileAttachment** - File attachment support in messages
- [x] **FileAccessProtocol** - Binary protocol for access requests/responses
- [x] **PasswordSetupView** - Enhanced password setup with strength indicator
- [x] **FileAccessRequestView** - UI for managing file access requests
- [x] **ChatViewModel+Storage** - Helper extension for storage integration

## 🔧 Integration Steps Required

### 1. ChatViewModel Integration

Add to `ChatViewModel.swift`:

```swift
// Add published property for file access requests
@Published var pendingFileAccessRequests: [SecureFileManager.FileAccessRequest] = []

// In init() or onAppear
func initializeStorage() {
    // Load file metadata
    try? SecureFileManager.shared.loadMetadata()
    
    // Load stored messages if password is set
    if SecureMessageStore.shared.hasActivePassword() {
        loadAllStoredMessages()
    }
}

// In message receive handler (didReceiveMessage or similar)
func handleIncomingMessage(_ message: EdgepulseMessage) {
    // ... existing code ...
    
    // Auto-save message
    saveMessageToStorage(message)
    
    // Handle file attachment if present
    if let attachment = message.fileAttachment {
        handleFileAttachment(attachment, from: message)
    }
}

// Add file attachment handler
private func handleFileAttachment(_ attachment: EdgepulseMessage.FileAttachment, from message: EdgepulseMessage) {
    do {
        // Try to access file
        let (data, metadata) = try decryptFile(attachment.fileId)
        // File accessible - can display it
    } catch {
        // Access denied - create request
        if let request = requestFileAccess(attachment.fileId) {
            // Send request to file owner via mesh
            sendFileAccessRequest(request, to: message.senderPeerID)
        }
    }
}
```

### 2. Mesh Protocol Integration

Add to your mesh protocol handler:

```swift
// Add packet types
enum EdgepulsePacketType {
    // ... existing types ...
    case fileAccessRequest
    case fileAccessResponse
}

// In packet receive handler
func handlePacket(_ data: Data, from peer: PeerID) {
    // ... existing packet handling ...
    
    // Handle file access request
    if let request = FileAccessRequestPacket.decode(data) {
        let accessRequest = SecureFileManager.FileAccessRequest(
            requestId: request.requestId,
            fileId: request.fileId,
            requesterId: request.requesterId,
            requesterNickname: request.requesterNickname,
            timestamp: request.timestamp
        )
        chatViewModel.handleFileAccessRequest(accessRequest)
    }
    
    // Handle file access response
    if let response = FileAccessResponsePacket.decode(data) {
        let accessResponse = SecureFileManager.FileAccessResponse(
            requestId: response.requestId,
            fileId: response.fileId,
            granted: response.granted,
            encryptedFileKey: response.encryptedFileKey
        )
        try? chatViewModel.handleFileAccessResponse(accessResponse)
    }
}

// Send file access request
func sendFileAccessRequest(_ request: SecureFileManager.FileAccessRequest, to peer: PeerID?) {
    guard let peer = peer else { return }
    
    let packet = FileAccessRequestPacket(
        requestId: request.requestId,
        fileId: request.fileId,
        requesterId: request.requesterId,
        requesterNickname: request.requesterNickname,
        timestamp: request.timestamp
    )
    
    if let data = packet.encode() {
        sendPacket(data, to: peer)
    }
}

// Send file access response
func sendFileAccessResponse(_ response: SecureFileManager.FileAccessResponse, to peerId: String) {
    guard let peer = PeerID(str: peerId) else { return }
    
    let packet = FileAccessResponsePacket(
        requestId: response.requestId,
        fileId: response.fileId,
        granted: response.granted,
        encryptedFileKey: response.encryptedFileKey
    )
    
    if let data = packet.encode() {
        sendPacket(data, to: peer)
    }
}
```

### 3. UI Integration

#### Add File Attachment Button
In your message input view:

```swift
Button(action: { showFilePicker = true }) {
    Image(systemName: "paperclip")
}
.fileImporter(isPresented: $showFilePicker, allowedContentTypes: [.image, .pdf, .data]) { result in
    switch result {
    case .success(let url):
        handleFileSelection(url)
    case .failure(let error):
        print("File selection error: \(error)")
    }
}

func handleFileSelection(_ url: URL) {
    do {
        // Encrypt and store file
        let fileId = try chatViewModel.encryptAndStoreFile(url, mimeType: url.mimeType)
        
        // Create message with attachment
        let attachment = EdgepulseMessage.FileAttachment(
            fileId: fileId,
            fileName: url.lastPathComponent,
            mimeType: url.mimeType,
            fileSize: Int64(url.fileSize ?? 0),
            isEncrypted: true
        )
        
        // Send message with attachment
        chatViewModel.sendMessageWithAttachment("Sent a file", attachment: attachment)
    } catch {
        print("Failed to attach file: \(error)")
    }
}
```

#### Display File Attachments in Messages
In your message bubble view:

```swift
if let attachment = message.fileAttachment {
    FileAttachmentView(attachment: attachment, message: message)
}

struct FileAttachmentView: View {
    let attachment: EdgepulseMessage.FileAttachment
    let message: EdgepulseMessage
    @EnvironmentObject var chatViewModel: ChatViewModel
    @State private var fileData: Data?
    @State private var isLoading = false
    @State private var accessDenied = false
    
    var body: some View {
        HStack {
            Image(systemName: iconForMimeType(attachment.mimeType))
            VStack(alignment: .leading) {
                Text(attachment.fileName)
                    .font(.caption)
                Text(formatFileSize(attachment.fileSize))
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            Spacer()
            
            if isLoading {
                ProgressView()
            } else if accessDenied {
                Button("Request Access") {
                    requestAccess()
                }
            } else if fileData != nil {
                Button("View") {
                    // Show file
                }
            } else {
                Button("Download") {
                    loadFile()
                }
            }
        }
        .padding(8)
        .background(Color.secondary.opacity(0.1))
        .cornerRadius(8)
    }
    
    private func loadFile() {
        isLoading = true
        do {
            let (data, _) = try chatViewModel.decryptFile(attachment.fileId)
            fileData = data
            accessDenied = false
        } catch {
            accessDenied = true
        }
        isLoading = false
    }
    
    private func requestAccess() {
        if let request = chatViewModel.requestFileAccess(attachment.fileId) {
            // Request created, will be sent via mesh
            // Show confirmation to user
        }
    }
}
```

#### Add File Access Requests View
In your settings or main view:

```swift
NavigationLink("File Access Requests (\(chatViewModel.pendingFileAccessRequests.count))") {
    FileAccessRequestsListView(ownerId: chatViewModel.myPeerID?.id ?? "")
}
```

### 4. App Launch Integration

Already integrated in `EdgepulseApp.swift`, but ensure:

```swift
// In ContentView.onAppear or similar
.onAppear {
    // Initialize storage
    chatViewModel.initializeStorage()
    
    // Load pending file access requests
    chatViewModel.pendingFileAccessRequests = chatViewModel.getPendingFileAccessRequests()
}
```

## 🧪 Testing Checklist

- [ ] Password setup on first launch
- [ ] Password strength validation
- [ ] Message encryption/decryption
- [ ] Message persistence across app restarts
- [ ] File encryption/storage
- [ ] File access request creation
- [ ] File access grant/deny
- [ ] File decryption after access granted
- [ ] Multiple chat conversations
- [ ] Private vs public message storage
- [ ] File metadata management
- [ ] Error handling for wrong password
- [ ] Keychain integration

## 📝 Notes

### Current Limitations
- File keys are transmitted directly (should use public key encryption)
- No automatic message sync between devices
- No backup/restore mechanism
- Password cannot be recovered

### Future Enhancements
- Implement public key encryption for file key exchange
- Add biometric authentication
- Implement secure backup
- Add message expiration/auto-delete
- Implement forward secrecy

## 🔒 Security Reminders

1. **Never log passwords or encryption keys**
2. **Always use secure random for key generation**
3. **Clear sensitive data from memory after use**
4. **Validate all user input**
5. **Use constant-time comparison for password verification**
6. **Implement rate limiting for password attempts**

## 📚 Documentation

See `SECURE_STORAGE_IMPLEMENTATION.md` for detailed documentation.
