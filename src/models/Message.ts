export interface Message {
    id: string;
    senderId: string;
    receiverId: string;
    content: string;
    isEncrypted?: boolean;
    password?: string;
    fileAccessRequests?: FileAccessRequest[];
}

export interface FileAccessRequest {
    requesterId: string;
    requesterName: string;
    fileId: string;
    status: 'pending' | 'approved' | 'denied';
    timestamp: number;
}