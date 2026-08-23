import SwiftUI

@available(iOS 26.0, macOS 26.0, *)
@MainActor
struct FirefoxPasswordsLibraryView: View {
    @Bindable var model: FirefoxSyncViewModel
    let contextProvider: @MainActor @Sendable () -> XanhCredentialContext?
    @State private var editor: FirefoxCredentialEditorState?
    @State private var credentialToDelete: XanhCredentialRecord?

    var body: some View {
        List {
            Section {
                Text(model.passwordsStatus)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                if let origin = contextProvider()?.canonicalTopFrameOrigin {
                    LabeledContent("Exact origin", value: origin)
                }
                Button("Refresh passwords", systemImage: "arrow.clockwise") {
                    Task { await model.loadSiteCredentials(contextProvider: contextProvider) }
                }
                Button("Add password", systemImage: "plus") {
                    guard model.snapshot.vaultUnlocked,
                          contextProvider()?.isAllowed == true else { return }
                    editor = FirefoxCredentialEditorState(record: nil)
                }
                .disabled(!model.snapshot.vaultUnlocked || contextProvider()?.isAllowed != true)
            }

            Section("Saved logins") {
                ForEach(model.siteCredentials) { credential in
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(credential.displayUsername)
                                .lineLimit(1)
                            Text("Password saved")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            if credential.timePasswordChangedEpochMillis > 0 {
                                Text(passwordChangedLabel(credential.timePasswordChangedEpochMillis))
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)

                        Menu("Password actions", systemImage: "ellipsis.circle") {
                            Button("Edit", systemImage: "pencil") {
                                guard model.snapshot.vaultUnlocked,
                                      let context = contextProvider(),
                                      credential.isAllowed(for: context) else { return }
                                editor = FirefoxCredentialEditorState(record: credential)
                            }
                            Button("Delete", systemImage: "trash", role: .destructive) {
                                guard let context = contextProvider(),
                                      credential.isAllowed(for: context) else { return }
                                credentialToDelete = credential
                            }
                        }
                        .labelStyle(.iconOnly)
                        .disabled(contextProvider()?.isAllowed != true)
                    }
                }
            }
        }
        .navigationTitle("Firefox Passwords")
        .privacySensitive()
        .task(id: contextProvider()?.documentURL.absoluteString) {
            await model.loadSiteCredentials(contextProvider: contextProvider)
        }
        .onChange(of: contextProvider()) { _, _ in
            editor = nil
            credentialToDelete = nil
            model.clearCredentialLibrary(detail: "The current page changed.")
        }
        .onChange(of: model.snapshot.vaultUnlocked) { _, unlocked in
            guard !unlocked else { return }
            editor = nil
            credentialToDelete = nil
            model.clearCredentialLibrary(detail: "Password vault locked.")
        }
        .onDisappear { model.clearCredentialLibrary() }
        .sheet(item: $editor) { state in
            FirefoxCredentialEditorSheet(initial: state) { draft in
                guard model.snapshot.vaultUnlocked,
                      contextProvider()?.isAllowed == true else { return }
                if let record = state.record {
                    Task {
                        await model.updateCredential(
                            record,
                            draft: draft,
                            contextProvider: contextProvider
                        )
                    }
                } else {
                    Task {
                        await model.addCredential(
                            draft: draft,
                            contextProvider: contextProvider
                        )
                    }
                }
            }
        }
        .confirmationDialog(
            "Delete this saved password?",
            isPresented: Binding(
                get: { credentialToDelete != nil },
                set: { if !$0 { credentialToDelete = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete password", role: .destructive) {
                guard let credential = credentialToDelete else { return }
                credentialToDelete = nil
                Task {
                    await model.deleteCredential(
                        credential,
                        contextProvider: contextProvider
                    )
                }
            }
            Button("Cancel", role: .cancel) { credentialToDelete = nil }
        } message: {
            Text("The exact login ID and current HTTPS origin are revalidated before deletion.")
        }
    }

    private func passwordChangedLabel(_ epochMillis: Int64) -> String {
        "Changed " + Date(timeIntervalSince1970: Double(epochMillis) / 1_000).formatted(
            date: .abbreviated,
            time: .shortened
        )
    }
}

@available(iOS 26.0, macOS 26.0, *)
private struct FirefoxCredentialEditorSheet: View {
    let initial: FirefoxCredentialEditorState
    let onSave: (XanhCredentialDraft) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var username: String
    @State private var password: String

    init(
        initial: FirefoxCredentialEditorState,
        onSave: @escaping (XanhCredentialDraft) -> Void
    ) {
        self.initial = initial
        self.onSave = onSave
        _username = State(initialValue: initial.username)
        _password = State(initialValue: initial.password)
    }

    var body: some View {
        NavigationStack {
            Form {
                TextField("Username", text: $username)
                    .textContentType(.username)
                SecureField("Password", text: $password)
                    .textContentType(.password)
                Text("Xanh stores this login only for the exact HTTPS origin shown in the password library. The value is never filled until you choose it from the native picker.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .privacySensitive()
            .navigationTitle(initial.record == nil ? "Add Password" : "Edit Password")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        let draft = XanhCredentialDraft(
                            usernameField: initial.usernameField,
                            passwordField: initial.passwordField,
                            username: username,
                            password: password
                        )
                        guard XanhCredentialPolicy.isValidUsername(draft.username),
                              XanhCredentialPolicy.isValidPassword(draft.password),
                              XanhCredentialPolicy.isValidField(draft.usernameField),
                              XanhCredentialPolicy.isValidField(draft.passwordField) else { return }
                        onSave(draft)
                        dismiss()
                    }
                    .disabled(
                        !XanhCredentialPolicy.isValidUsername(username)
                            || !XanhCredentialPolicy.isValidPassword(password)
                    )
                }
            }
        }
    }
}

private struct FirefoxCredentialEditorState: Identifiable {
    let id = UUID()
    let record: XanhCredentialRecord?
    let usernameField: String
    let passwordField: String
    let username: String
    let password: String

    init(record: XanhCredentialRecord?) {
        self.record = record
        usernameField = record?.usernameField ?? ""
        passwordField = record?.passwordField ?? ""
        username = record?.username ?? ""
        password = record?.password ?? ""
    }
}
