//
// FileAccessRequestView.swift
// edgepulse
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import SwiftUI

struct FileAccessRequestView: View {
    let request: SecureFileManager.FileAccessRequest
    let onGrant: () -> Void
    let onDeny: () -> Void
    
    @State private var fileMetadata: SecureFileManager.FileMetadata?
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "lock.doc.fill")
                    .foregroundColor(.orange)
                    .font(.title2)
                
                VStack(alignment: .leading, spacing: 4) {
                    Text("File Access Request")
                        .font(.headline)
                    Text(request.requesterNickname)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                
                Spacer()
            }
            
            if let metadata = fileMetadata {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("File:")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Text(metadata.originalFileName)
                            .font(.caption)
                            .fontWeight(.medium)
                    }
                    
                    HStack {
                        Text("Size:")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Text(formatFileSize(metadata.fileSize))
                            .font(.caption)
                    }
                }
                .padding(.vertical, 4)
            }
            
            Text("wants to access your file")
                .font(.subheadline)
                .foregroundColor(.secondary)
            
            HStack(spacing: 12) {
                Button(action: onDeny) {
                    HStack {
                        Image(systemName: "xmark.circle.fill")
                        Text("Deny")
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(Color.red.opacity(0.1))
                    .foregroundColor(.red)
                    .cornerRadius(8)
                }
                
                Button(action: onGrant) {
                    HStack {
                        Image(systemName: "checkmark.circle.fill")
                        Text("Grant Access")
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(Color.green.opacity(0.1))
                    .foregroundColor(.green)
                    .cornerRadius(8)
                }
            }
        }
        .padding()
        .background(Color(.systemBackground))
        .cornerRadius(12)
        .shadow(radius: 2)
        .onAppear {
            fileMetadata = SecureFileManager.shared.getFileMetadata(request.fileId)
        }
    }
    
    private func formatFileSize(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}

struct FileAccessRequestsListView: View {
    let ownerId: String
    @State private var requests: [SecureFileManager.FileAccessRequest] = []
    @State private var showingAlert = false
    @State private var alertMessage = ""
    
    var body: some View {
        NavigationView {
            Group {
                if requests.isEmpty {
                    VStack(spacing: 16) {
                        Image(systemName: "tray.fill")
                            .font(.system(size: 60))
                            .foregroundColor(.secondary)
                        Text("No pending requests")
                            .font(.headline)
                            .foregroundColor(.secondary)
                    }
                } else {
                    ScrollView {
                        VStack(spacing: 12) {
                            ForEach(requests, id: \.requestId) { request in
                                FileAccessRequestView(
                                    request: request,
                                    onGrant: { grantAccess(request) },
                                    onDeny: { denyAccess(request) }
                                )
                            }
                        }
                        .padding()
                    }
                }
            }
            .navigationTitle("File Access Requests")
            .alert("File Access", isPresented: $showingAlert) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(alertMessage)
            }
            .onAppear(perform: loadRequests)
        }
    }
    
    private func loadRequests() {
        requests = SecureFileManager.shared.getPendingRequests(forOwnerId: ownerId)
    }
    
    private func grantAccess(_ request: SecureFileManager.FileAccessRequest) {
        do {
            let response = try SecureFileManager.shared.grantAccess(requestId: request.requestId, ownerId: ownerId)
            
            // TODO: Send response to requester via mesh network
            
            alertMessage = "Access granted to \(request.requesterNickname)"
            showingAlert = true
            
            // Remove from list
            requests.removeAll { $0.requestId == request.requestId }
        } catch {
            alertMessage = "Failed to grant access: \(error.localizedDescription)"
            showingAlert = true
        }
    }
    
    private func denyAccess(_ request: SecureFileManager.FileAccessRequest) {
        do {
            let response = try SecureFileManager.shared.denyAccess(requestId: request.requestId, ownerId: ownerId)
            
            // TODO: Send response to requester via mesh network
            
            alertMessage = "Access denied for \(request.requesterNickname)"
            showingAlert = true
            
            // Remove from list
            requests.removeAll { $0.requestId == request.requestId }
        } catch {
            alertMessage = "Failed to deny access: \(error.localizedDescription)"
            showingAlert = true
        }
    }
}
