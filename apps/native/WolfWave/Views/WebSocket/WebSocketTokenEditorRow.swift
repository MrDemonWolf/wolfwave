//
//  WebSocketTokenEditorRow.swift
//  WolfWave
//
//  Created by Nathanial Henniges on 2026-08-17.
//  Copyright © 2026 MrDemonWolf, Inc. All rights reserved.
//

import SwiftUI

// MARK: - WebSocket Token Editor

/// Shared editor for the two role-specific credentials. Keeping one row
/// implementation prevents overlay and Stream Deck validation or masking
/// behavior from drifting while preserving the existing settings-card design.
///
/// Rendered by `WebSocketCustomOverlayCard` (overlay role) and
/// `StreamDeckSettingsView` (control role). Saving or regenerating writes the
/// Keychain, pushes the new token to the running `WebSocketServerService`, and,
/// for the overlay role, posts `websocketAuthTokenChanged` so the widget URLs
/// refresh.
struct WebSocketTokenEditorRow: View {
    // MARK: - Properties

    /// Which credential this row edits. Picks the copy, identifiers, and the
    /// server update call.
    let role: WebSocketAuthToken.Role
    /// Row title, e.g. "Overlay Token".
    let title: String
    /// One-line note under the title about what the token can do.
    let subtitle: String
    /// The persisted token, owned by the parent. Updated here after a
    /// successful save or regenerate.
    @Binding var currentToken: String
    /// Streamer Mode: forces the field hidden and disables reveal, copy,
    /// editing, and regenerate.
    let streamerMode: Bool
    /// The other role's token as the parent last loaded it. Only a fallback for
    /// the "must be different" check; `persistTokenEdit` re-reads the live
    /// value first.
    let otherToken: String

    /// Text in the field. Mirrors `currentToken` until the user edits it.
    @State private var tokenDraft = ""
    /// Shows the plain `TextField` instead of the `SecureField`.
    @State private var isTokenRevealed = false
    /// Inline validation or save error under the field.
    @State private var tokenError: String?
    /// Presents the regenerate confirmation dialog.
    @State private var showingRegenerateConfirm = false
    /// True while a save is in flight; disables the field and Save, and makes
    /// a second submit a no-op.
    @State private var isSavingToken = false

    /// Shorthand for the standard settings card inset.
    private let cardPadding = AppConstants.SettingsUI.cardPadding

    /// Convenience for the many overlay-vs-control branches.
    private var isOverlay: Bool { role == .overlay }

    /// True when the draft differs from the saved token (ignoring surrounding
    /// whitespace) and isn't empty. Shows Save / Cancel.
    private var hasTokenEdits: Bool {
        let normalized = WebSocketAuthToken.normalizedInput(tokenDraft)
        return !normalized.isEmpty && normalized != currentToken
    }

    // Role-specific accessibility identifiers. The overlay ones keep their
    // original names so existing UI tests keep matching.

    /// Identifier for the revealed (plain) field.
    private var visibleFieldIdentifier: String {
        isOverlay ? "websocketTokenFieldVisible" : "websocketControlTokenFieldVisible"
    }

    /// Identifier for the masked field.
    private var hiddenFieldIdentifier: String {
        isOverlay ? "websocketTokenFieldHidden" : "websocketControlTokenFieldHidden"
    }

    /// Identifier for the eye button.
    private var revealButtonIdentifier: String {
        isOverlay ? "websocketTokenRevealButton" : "websocketControlTokenRevealButton"
    }

    /// Identifier for the Copy button.
    private var copyButtonIdentifier: String {
        isOverlay ? "copyWebsocketTokenButton" : "copyWebsocketControlTokenButton"
    }

    /// Identifier for the inline error line.
    private var errorIdentifier: String {
        isOverlay ? "websocketTokenError" : "websocketControlTokenError"
    }

    /// Identifier for Regenerate.
    private var regenerateButtonIdentifier: String {
        isOverlay ? "regenerateWebsocketTokenButton" : "regenerateWebsocketControlTokenButton"
    }

    /// Identifier for Save.
    private var saveButtonIdentifier: String {
        isOverlay ? "saveWebsocketTokenButton" : "saveWebsocketControlTokenButton"
    }

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: DSSpace.s2) {
            HStack(alignment: .firstTextBaseline, spacing: DSSpace.s2) {
                VStack(alignment: .leading, spacing: DSSpace.s0) {
                    HStack(spacing: DSSpace.s1h) {
                        Image(systemName: "lock.fill")
                            .font(.system(size: DSFont.Size.sm))
                            .foregroundStyle(.secondary)
                        Text(title).font(.system(size: DSFont.Size.base, weight: .medium))
                        if streamerMode { StreamerModeBadge() }
                    }
                    Text(subtitle)
                        .font(.system(size: DSFont.Size.sm))
                        .foregroundStyle(.tertiary)
                }
                Spacer()
            }

            HStack(spacing: DSSpace.s1h) {
                Group {
                    if isTokenRevealed && !streamerMode {
                        TextField("Token", text: $tokenDraft)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: DSFont.Size.body, design: .monospaced))
                            .autocorrectionDisabled(true)
                            .onSubmit { saveTokenEdit() }
                            .accessibilityIdentifier(visibleFieldIdentifier)
                    } else {
                        SecureField("Token", text: $tokenDraft)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: DSFont.Size.body, design: .monospaced))
                            .onSubmit { saveTokenEdit() }
                            .disabled(streamerMode)
                            .accessibilityIdentifier(hiddenFieldIdentifier)
                    }
                }
                .disabled(isSavingToken)

                DSIconButton(
                    systemImage: isTokenRevealed ? "eye.slash" : "eye",
                    action: { isTokenRevealed.toggle() },
                    accessibilityLabel: isTokenRevealed ? "Hide token" : "Reveal token",
                    accessibilityIdentifier: revealButtonIdentifier
                )
                .help(isTokenRevealed ? "Hide token" : "Reveal token")
                .disabled(streamerMode)

                CopyButton(
                    text: currentToken,
                    label: "Copy",
                    copiedLabel: "Copied",
                    isDisabled: currentToken.isEmpty || streamerMode,
                    accessibilityLabel: isOverlay
                        ? "Copy overlay token"
                        : "Copy Stream Deck control token",
                    accessibilityIdentifier: copyButtonIdentifier,
                    isSensitive: true
                )
            }

            if let tokenError {
                HStack(spacing: DSSpace.s1h) {
                    Image(systemName: "exclamationmark.circle.fill")
                        .font(.system(size: DSFont.Size.sm))
                    Text(tokenError).font(.system(size: DSFont.Size.sm))
                }
                .foregroundStyle(DSColor.error)
                .accessibilityIdentifier(errorIdentifier)
            }

            HStack(spacing: DSSpace.s2) {
                Button(role: .destructive) {
                    showingRegenerateConfirm = true
                } label: {
                    HStack(spacing: DSSpace.s1) {
                        Image(systemName: "arrow.clockwise").font(.system(size: DSFont.Size.sm))
                        Text("Regenerate").font(.system(size: DSFont.Size.sm))
                    }
                    .foregroundStyle(DSColor.error)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(streamerMode)
                .help(regenerateHelp)
                .accessibilityIdentifier(regenerateButtonIdentifier)

                if hasTokenEdits {
                    Button("Save") { saveTokenEdit() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .disabled(streamerMode || isSavingToken)
                        .accessibilityIdentifier(saveButtonIdentifier)

                    Button("Cancel") {
                        tokenDraft = currentToken
                        tokenError = nil
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                Spacer()
            }
        }
        .padding(.horizontal, cardPadding)
        .padding(.vertical, DSSpace.s4)
        .onAppear {
            if tokenDraft.isEmpty { tokenDraft = currentToken }
        }
        .onChange(of: currentToken) { _, newValue in
            tokenDraft = newValue
            tokenError = nil
        }
        .confirmationDialog(
            isOverlay ? "Regenerate overlay token?" : "Regenerate control token?",
            isPresented: $showingRegenerateConfirm,
            titleVisibility: .visible
        ) {
            Button("Regenerate", role: .destructive) { regenerateToken() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                isOverlay
                    ? "Active overlays disconnect until you copy the new URL back into OBS."
                    : "Stream Deck disconnects until you copy the new control token into its settings."
            )
        }
    }

    // MARK: - Private Helpers

    /// Tooltip for Regenerate, explaining the Streamer Mode lock when relevant.
    private var regenerateHelp: String {
        if streamerMode { return "Turn off Streamer Mode to regenerate this token." }
        return isOverlay
            ? "Generate a new overlay token. Active overlays will disconnect until updated."
            : "Generate a new control token. Stream Deck will disconnect until updated."
    }

    /// Fire-and-forget entry for Return and the Save button.
    private func saveTokenEdit() {
        Task { await persistTokenEdit() }
    }

    /// Validates and saves the draft.
    ///
    /// Order: normalize (trim, lowercase), ignore empty / unchanged drafts
    /// (reset the field), require exactly 64 hex characters, refuse a value equal to the live counterpart
    /// token (constant-time compare), then persist off the main actor and push
    /// it to the server. Every failure leaves the saved token untouched and
    /// sets `tokenError`.
    private func persistTokenEdit() async {
        guard !isSavingToken else { return }
        isSavingToken = true
        defer { isSavingToken = false }
        let trimmed = WebSocketAuthToken.normalizedInput(tokenDraft)
        guard !trimmed.isEmpty, trimmed != currentToken else {
            tokenDraft = currentToken
            return
        }
        guard WebSocketAuthToken.isValid(trimmed) else {
            tokenError = "Use exactly 64 hex characters (0-9, a-f)."
            return
        }
        // Read the counterpart from the Keychain rather than trusting the copy
        // this view was handed. `otherToken` is loaded once by the parent's
        // `.task` and never refreshed, and since the overlay and control editors
        // now live in two different panes, each one's cached copy goes stale the
        // moment the other pane rotates its token. Validating against that cache
        // could accept a value equal to the live counterpart, and the entire role
        // separation rests on those two being different: an OBS browser source
        // holding a token equal to the control token would be a command channel.
        //
        // Falls back to the cached value only if the Keychain read fails, which
        // keeps the guard strictly no weaker than before.
        let counterpartRole = role.counterpart
        let counterpart = await Task.detached(priority: .userInitiated) {
            WebSocketAuthToken.currentOrCreate(for: counterpartRole)
        }.value
        let liveOther = counterpart.isEmpty ? otherToken : counterpart
        guard liveOther.isEmpty || !WebSocketAuthToken.constantTimeEquals(trimmed, liveOther) else {
            tokenError = "Overlay and control tokens must be different."
            return
        }

        do {
            let savedRole = role
            try await Task.detached(priority: .userInitiated) {
                try WebSocketAuthToken.persist(trimmed, for: savedRole)
            }.value
            currentToken = trimmed
            tokenDraft = trimmed
            tokenError = nil
            applyTokenToServer(trimmed)
        } catch {
            Log.error(
                "WebSocketSettings: Failed to save " + role.rawValue + " token: "
                    + String(describing: error),
                category: .websocket
            )
            tokenError = "Couldn't save token. Try again."
        }
    }

    /// Generates and saves a fresh random token for this role, then applies it.
    /// The Keychain write runs off the main actor (like `persistTokenEdit`);
    /// on failure the old token stays active.
    private func regenerateToken() {
        Task { await performRegenerate() }
    }

    /// Async body of `regenerateToken()`. Shares `isSavingToken` with the save
    /// path so a regenerate and a save can't race each other's Keychain write.
    private func performRegenerate() async {
        guard !isSavingToken else { return }
        isSavingToken = true
        defer { isSavingToken = false }
        let rotatedRole = role
        do {
            let fresh = try await Task.detached(priority: .userInitiated) {
                try WebSocketAuthToken.rotate(rotatedRole)
            }.value
            currentToken = fresh
            tokenDraft = fresh
            tokenError = nil
            applyTokenToServer(fresh)
        } catch {
            Log.error(
                "WebSocketSettings: Failed to rotate " + role.rawValue + " token: "
                    + String(describing: error),
                category: .websocket
            )
            tokenError = "Couldn't save the new token. Your current token is still active."
        }
    }

    /// Hands the new token to the running server (which restarts an active
    /// listener so every client re-authenticates) and, for the overlay role,
    /// posts `websocketAuthTokenChanged`. With no server instance the server
    /// call is skipped.
    private func applyTokenToServer(_ token: String) {
        let server = AppDelegate.shared?.websocketServer
        Task {
            switch role {
            case .overlay:
                await server?.updateOverlayToken(token)
            case .control:
                await server?.updateControlToken(token)
            }
        }
        if isOverlay {
            NotificationCenter.default.post(name: .websocketAuthTokenChanged, object: nil)
        }
    }
}
