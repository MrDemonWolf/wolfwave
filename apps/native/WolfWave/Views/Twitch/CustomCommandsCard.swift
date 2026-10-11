//
//  CustomCommandsCard.swift
//  WolfWave
//
//  Created by Nathanial Henniges on 2026-07-15.
//  Copyright © 2026 MrDemonWolf, Inc. All rights reserved.
//

import SwiftUI

/// Custom Commands card for the Twitch settings pane.
///
/// Lists the user's own chat commands and hosts the add/edit sheet. Backed by
/// the shared ``CustomCommandStore`` singleton (the same instance the dispatcher
/// reads), so a saved edit takes effect on the next chat line.
///
/// Editing stays open while Twitch is disconnected: the store is local, so a
/// streamer can set commands up before going live. The connection notice only
/// explains that the commands won't reply until Twitch is connected.
struct CustomCommandsCard: View {

    /// Drives the connection notice. Commands reply only while Twitch chat is
    /// connected and the sign-in is valid.
    let viewModel: TwitchViewModel

    private let expiredMessage =
        "Your Twitch sign-in expired. You can still edit these, but they won't reply until you reconnect above."
    private let disconnectedMessage =
        "You can set these up now. They reply in chat once you connect with Twitch above."

    /// The shared store; `@State` pins the singleton's identity for the view's
    /// lifetime while Observation tracks its property reads.
    @State private var store = CustomCommandStore.shared

    /// The command currently open in the editor sheet, if any.
    @State private var editing: CustomCommand?

    /// `true` when `editing` is a brand-new command (Save appends) vs an edit.
    @State private var isNewCommand = false

    /// Outcome of the last announcement send; non-`ok` shows a banner.
    @AppStorage(AppConstants.UserDefaults.customCommandAnnounceStatus)
    private var announceStatusRaw = AnnounceStatus.ok.rawValue

    private var announceBanner: String? {
        guard store.commands.contains(where: { $0.enabled && $0.delivery == .announce }) else { return nil }
        return AnnounceStatus(rawValue: announceStatusRaw)?.bannerMessage
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DSSpace.s6) {
            SectionHeaderWithStatus(
                title: "Custom Commands",
                subtitle: "Make your own chat commands with a fixed reply.",
                prominence: .section
            )

            TwitchConnectionNotice(
                isConnected: viewModel.channelConnected,
                reauthNeeded: viewModel.reauthNeeded,
                expiredMessage: expiredMessage,
                disconnectedMessage: disconnectedMessage
            )

            if let announceBanner {
                CalloutBanner(announceBanner, title: "Announcements need setup", style: .warning)
                    .accessibilityIdentifier("customCommandAnnounceBanner")
            }

            if store.commands.isEmpty {
                emptyState
            } else {
                VStack(spacing: 1) {
                    ForEach(store.commands) { command in
                        row(for: command)
                    }
                }
                .cardStyleUnpadded()
            }

            Button {
                isNewCommand = true
                editing = CustomCommand()
            } label: {
                Label("Add command", systemImage: "plus")
            }
            .controlSize(.small)
            .accessibilityIdentifier("addCustomCommand")

            HintRow("Use variables like $user, $touser, $args, $1, $song in your reply.")
        }
        .sheet(item: $editing) { command in
            CustomCommandEditor(
                command: command,
                isNew: isNewCommand,
                store: store,
                onSave: { saved in
                    // The editor only enables Save for a valid draft, but the
                    // store re-checks the whole set. Keep the sheet open if it
                    // still refuses, so the streamer's typing is never lost.
                    let stored = isNewCommand ? store.add(saved) : store.update(saved)
                    if stored { editing = nil }
                },
                onDelete: {
                    store.delete(id: command.id)
                    editing = nil
                },
                onCancel: { editing = nil }
            )
        }
    }

    // MARK: - Rows

    private var emptyState: some View {
        Text("No custom commands yet. Add one to reply to a chat trigger.")
            .fieldSubtitle()
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(AppConstants.SettingsUI.cardPadding)
            .cardStyle()
    }

    private func row(for command: CustomCommand) -> some View {
        HStack(spacing: DSSpace.s3) {
            VStack(alignment: .leading, spacing: DSSpace.s0) {
                Text(command.normalizedTrigger.isEmpty ? "(no trigger)" : command.normalizedTrigger)
                    .font(.system(size: DSFont.Size.base, weight: .semibold))
                    .foregroundStyle(command.enabled ? .primary : .secondary)

                Text(command.response.isEmpty ? "No reply set" : command.response)
                    .font(.system(size: DSFont.Size.sm))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            Spacer(minLength: DSSpace.s2)

            if command.delivery != .reply {
                StatusChip(text: command.delivery.label, color: DSColor.info)
            }
            StatusChip(text: command.permission.label, color: .accentColor)

            Toggle("", isOn: enabledBinding(for: command))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .accessibilityLabel("Enable \(command.normalizedTrigger)")
                .accessibilityIdentifier("customCommandToggle.\(command.normalizedTrigger)")
                .accessibilityValue(command.enabled ? "Enabled" : "Disabled")

            DSIconButton(
                systemImage: "pencil",
                action: {
                    isNewCommand = false
                    editing = command
                },
                accessibilityLabel: "Edit \(command.normalizedTrigger)"
            )
        }
        .padding(.horizontal, AppConstants.SettingsUI.cardPadding)
        .padding(.vertical, DSSpace.s3)
        .overlay(alignment: .bottom) {
            if command.id != store.commands.last?.id {
                Divider().padding(.leading, AppConstants.SettingsUI.cardPadding)
            }
        }
    }

    /// A binding that flips a single command's `enabled` flag through the store
    /// (so the change persists and re-renders the list).
    private func enabledBinding(for command: CustomCommand) -> Binding<Bool> {
        Binding(
            get: { command.enabled },
            set: { newValue in
                var updated = command
                updated.enabled = newValue
                store.update(updated)
            }
        )
    }
}

// MARK: - Editor

/// Add/edit sheet for one custom command. Keeps a working copy so Cancel is a
/// true no-op; ``CustomCommandStore/validationIssue(for:)`` blocks Save and
/// names the problem under the field that needs fixing.
private struct CustomCommandEditor: View {

    @State private var draft: CustomCommand
    /// Fields the user has edited. A mistake shows only once its field is
    /// dirty, so a fresh sheet doesn't open covered in red.
    @State private var dirtyFields: Set<CustomCommandIssue.Field> = []
    let isNew: Bool
    let store: CustomCommandStore
    let onSave: (CustomCommand) -> Void
    let onDelete: () -> Void
    let onCancel: () -> Void

    init(
        command: CustomCommand,
        isNew: Bool,
        store: CustomCommandStore,
        onSave: @escaping (CustomCommand) -> Void,
        onDelete: @escaping () -> Void,
        onCancel: @escaping () -> Void
    ) {
        _draft = State(initialValue: command)
        self.isNew = isNew
        self.store = store
        self.onSave = onSave
        self.onDelete = onDelete
        self.onCancel = onCancel
    }

    private var issue: CustomCommandIssue? { store.validationIssue(for: draft) }
    private var isValid: Bool { issue == nil }

    /// Counted in Unicode scalars to match the Save gate and the send-time
    /// truncation, so the counter never reads under the limit for a reply
    /// that would be cut.
    private var replyLength: Int { draft.response.unicodeScalars.count }
    private var replyOverLimit: Bool { replyLength > AppConstants.Twitch.maxMessageLength }

    var body: some View {
        VStack(alignment: .leading, spacing: DSSpace.s5) {
            Text(isNew ? "New Command" : "Edit Command")
                .paneTitle()

            VStack(alignment: .leading, spacing: DSSpace.s2) {
                Text("Trigger").sectionEyebrow()
                TextField("!hug", text: $draft.trigger)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("customCommandTrigger")
                issueMessage(for: .trigger)
            }

            VStack(alignment: .leading, spacing: DSSpace.s2) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Reply").sectionEyebrow()
                    Spacer()
                    replyCounter
                }
                TextField("$user gives $touser a big hug!", text: $draft.response, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(2...5)
                    .accessibilityIdentifier("customCommandResponse")
                issueMessage(for: .reply)
            }

            HStack(spacing: DSSpace.s2) {
                Text("Who can use it").sectionEyebrow()
                Spacer()
                Picker("Permission", selection: $draft.permission) {
                    ForEach(CommandPermission.allCases) { permission in
                        Text(permission.label).tag(permission)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .controlSize(.small)
                .frame(maxWidth: AppConstants.SettingsUI.inlineFieldMaxWidth)
                .accessibilityIdentifier("customCommandPermission")
            }

            VStack(alignment: .leading, spacing: DSSpace.s1) {
                HStack(spacing: DSSpace.s2) {
                    Text("How it's sent").sectionEyebrow()
                    Spacer()
                    Picker("Delivery", selection: $draft.delivery) {
                        ForEach(ReplyDelivery.allCases) { delivery in
                            Text(delivery.label).tag(delivery)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .controlSize(.small)
                    .frame(maxWidth: AppConstants.SettingsUI.inlineFieldMaxWidth)
                    .accessibilityIdentifier("customCommandDelivery")
                }
                Text(draft.delivery.help)
                    .font(.system(size: DSFont.Size.sm))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: DSSpace.s2) {
                CommandAliasField(
                    aliases: $draft.aliases,
                    accessibilityIdentifier: "customCommandAliases"
                )
                issueMessage(for: .aliases)
            }

            CooldownSliderPair(
                everyone: .init(
                    label: "Everyone",
                    value: $draft.globalCooldown,
                    range: CustomCommand.globalCooldownRange,
                    step: CustomCommand.cooldownStep,
                    accessibilityIdentifier: "customCommand.everyoneCooldown"
                ),
                perPerson: .init(
                    label: "Per person",
                    value: $draft.userCooldown,
                    range: CustomCommand.userCooldownRange,
                    step: CustomCommand.cooldownStep,
                    accessibilityIdentifier: "customCommand.perUserCooldown"
                )
            )

            variableLegend

            Spacer(minLength: 0)

            HStack {
                if !isNew {
                    Button("Delete", role: .destructive, action: onDelete)
                        .accessibilityIdentifier("deleteCustomCommand")
                }
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Save") { onSave(normalized()) }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(!isValid)
                    .accessibilityIdentifier("saveCustomCommand")
            }
        }
        .padding(DSSpace.s7)
        .frame(width: 460)
        .frame(minHeight: 580)
        .onChange(of: draft.trigger) { dirtyFields.insert(.trigger) }
        .onChange(of: draft.aliases) { dirtyFields.insert(.aliases) }
        .onChange(of: draft.response) { dirtyFields.insert(.reply) }
    }

    /// The current issue, rendered under `field` once that field is dirty.
    ///
    /// Guidance for an unfilled field (no trigger yet, no reply yet) reads
    /// neutral and shows straight away; a real mistake waits for the field to
    /// be edited and then uses the error color.
    @ViewBuilder
    private func issueMessage(for field: CustomCommandIssue.Field) -> some View {
        if let issue, issue.field(trigger: draft.normalizedTrigger) == field {
            if issue.isNeutralHint {
                Text(issue.message)
                    .font(.system(size: DSFont.Size.sm))
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("customCommandHint.\(field)")
            } else if dirtyFields.contains(field) {
                FieldValidationRow(state: .invalid(issue.message))
                    .accessibilityIdentifier("customCommandError.\(field)")
            }
        }
    }

    /// Live reply length against Twitch's per-message limit.
    private var replyCounter: some View {
        Text("\(replyLength)/\(AppConstants.Twitch.maxMessageLength)")
            .font(.system(size: DSFont.Size.sm))
            .monospacedDigit()
            .foregroundStyle(replyOverLimit ? DSColor.error : Color.secondary)
            .accessibilityLabel(
                "\(replyLength) of \(AppConstants.Twitch.maxMessageLength) characters")
            .accessibilityIdentifier("customCommandReplyCounter")
    }

    /// A short reference of the supported variables.
    private var variableLegend: some View {
        VStack(alignment: .leading, spacing: DSSpace.s1) {
            Text("Variables").sectionEyebrow()
            Text("$user · $touser · $args · $1–$9 · $song · $lastsong")
                .font(.system(size: DSFont.Size.sm))
                .foregroundStyle(.secondary)
        }
    }

    /// Store the trigger in its normalized form so the list and matcher agree.
    private func normalized() -> CustomCommand {
        var result = draft
        result.trigger = draft.normalizedTrigger
        return result
    }
}

// MARK: - Preview

#Preview("Custom Commands") {
    let connected = TwitchViewModel()
    connected.channelConnected = true
    return CustomCommandsCard(viewModel: connected)
        .padding()
        .frame(width: 700)
}
