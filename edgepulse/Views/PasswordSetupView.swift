import SwiftUI

struct PasswordSetupView: View {
    @State private var password = ""
    @State private var confirmPassword = ""
    @State private var showError = false
    @State private var errorMessage = ""
    @State private var isProcessing = false
    @Binding var isPresented: Bool
    
    private var passwordStrength: PasswordStrength {
        if password.isEmpty { return .none }
        if password.count < 8 { return .weak }
        
        var strength = 0
        if password.count >= 12 { strength += 1 }
        if password.rangeOfCharacter(from: .uppercaseLetters) != nil { strength += 1 }
        if password.rangeOfCharacter(from: .lowercaseLetters) != nil { strength += 1 }
        if password.rangeOfCharacter(from: .decimalDigits) != nil { strength += 1 }
        if password.rangeOfCharacter(from: CharacterSet(charactersIn: "!@#$%^&*()_+-=[]{}|;:,.<>?")) != nil { strength += 1 }
        
        if strength >= 4 { return .strong }
        if strength >= 2 { return .medium }
        return .weak
    }
    
    private var canSubmit: Bool {
        !password.isEmpty && password == confirmPassword && password.count >= 8 && !isProcessing
    }
    
    var body: some View {
        NavigationView {
            Form {
                Section {
                    Text("Set a strong password to encrypt all your messages and files locally on this device.")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                
                Section(header: Text("Password")) {
                    SecureField("Enter Password", text: $password)
                        .textContentType(.newPassword)
                        .autocapitalization(.none)
                    
                    if !password.isEmpty {
                        HStack {
                            Text("Strength:")
                                .font(.caption)
                            Text(passwordStrength.description)
                                .font(.caption)
                                .foregroundColor(passwordStrength.color)
                            Spacer()
                        }
                    }
                    
                    SecureField("Confirm Password", text: $confirmPassword)
                        .textContentType(.newPassword)
                        .autocapitalization(.none)
                    
                    if !confirmPassword.isEmpty && password != confirmPassword {
                        Text("Passwords don't match")
                            .font(.caption)
                            .foregroundColor(.red)
                    }
                }
                
                Section {
                    Text("⚠️ Important: This password cannot be recovered. Make sure to remember it!")
                        .font(.caption)
                        .foregroundColor(.orange)
                }
                
                Section {
                    Button(action: setupPassword) {
                        HStack {
                            Spacer()
                            if isProcessing {
                                ProgressView()
                                    .progressViewStyle(CircularProgressViewStyle())
                            } else {
                                Text("Set Password")
                                    .fontWeight(.semibold)
                            }
                            Spacer()
                        }
                    }
                    .disabled(!canSubmit)
                }
            }
            .alert("Error", isPresented: $showError) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorMessage)
            }
            .navigationTitle("Setup Storage Password")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .interactiveDismissDisabled(true)
        }
    }
    
    private func setupPassword() {
        guard canSubmit else { return }
        
        // Validate password strength
        guard password.count >= 8 else {
            errorMessage = "Password must be at least 8 characters long"
            showError = true
            return
        }
        
        guard password == confirmPassword else {
            errorMessage = "Passwords don't match"
            showError = true
            return
        }
        
        isProcessing = true
        
        // Set password asynchronously
        DispatchQueue.global(qos: .userInitiated).async {
            SecureMessageStore.shared.setPassword(password)
            
            // Small delay to ensure keychain write completes
            Thread.sleep(forTimeInterval: 0.5)
            
            DispatchQueue.main.async {
                isProcessing = false
                
                // Verify it was saved
                if SecureMessageStore.shared.isPasswordSet() {
                    isPresented = false
                } else {
                    errorMessage = "Failed to save password. Please try again."
                    showError = true
                }
            }
        }
    }
}

enum PasswordStrength {
    case none, weak, medium, strong
    
    var description: String {
        switch self {
        case .none: return ""
        case .weak: return "Weak"
        case .medium: return "Medium"
        case .strong: return "Strong"
        }
    }
    
    var color: Color {
        switch self {
        case .none: return .gray
        case .weak: return .red
        case .medium: return .orange
        case .strong: return .green
        }
    }
}
