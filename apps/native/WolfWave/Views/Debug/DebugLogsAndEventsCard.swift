//
//  DebugLogsAndEventsCard.swift
//  WolfWave
//
//  Created by Nathanial Henniges on 2026-05-16.
//  Copyright © 2026 MrDemonWolf, Inc. All rights reserved.
//

#if DEBUG
import AppKit
import SwiftUI

/// DEBUG-only card combining log file utilities with a notification firehose for
/// manually posting any app-internal `NotificationCenter` event.
struct DebugLogsAndEventsCard: View {

    // MARK: - Properties

    /// Notification name to post. Picked from `AppConstants.Notifications.allNames`.
    @State private var selectedNotification: String =
        AppConstants.Notifications.allNames.first ?? ""
    /// Raw JSON typed by the user. An empty or `{}` body posts with no userInfo.
    @State private var userInfoJSON: String = "{}"
    /// Result line under the Post button. Its color keys off the "Posted" prefix,
    /// so keep that prefix on the success message.
    @State private var postStatus: String?
    /// Bumped (wrapping) to re-run the stats `.task`; refresh and Clear Log both bump it.
    @State private var refreshTick = 0

    /// Log file stats, loaded off-main via `.task(id: refreshTick)` so the
    /// card paints instantly. `logLineCount()` streams the entire log file
    /// through `fileQueue.sync` and would stall first paint on big logs.
    @State private var logURL: URL?
    @State private var logSize: Int64 = 0
    @State private var logLines: Int = 0
    @State private var logStatsLoaded = false

    var body: some View {
        VStack(alignment: .leading, spacing: DSSpace.s6) {
            Text("Log file stats, export, and notification probes.")
                .font(.system(size: DSFont.Size.body))
                .foregroundStyle(.secondary)

            logsSection
            Divider()
            firehoseSection
        }
        .cardStyle()
        .task(id: refreshTick) {
            // Deliberately does NOT reset `logStatsLoaded` here. Doing so swapped
            // the stats for a LoadingRow on every manual refresh and flickered.
            // DebugInspectorsCard keeps its last values for the same reason.
            let stats = await Task.detached(priority: .userInitiated) {
                (url: Log.exportLogFile(), size: Log.logFileSize(), lines: Log.logLineCount())
            }.value
            await MainActor.run {
                logURL = stats.url
                logSize = stats.size
                logLines = stats.lines
                logStatsLoaded = true
            }
        }
    }

    // MARK: - Logs

    /// Log file path and size, Reveal / Copy Path / Clear, and buttons that write
    /// one test line at each level (category `devTools`).
    private var logsSection: some View {
        VStack(alignment: .leading, spacing: DSSpace.s2) {
            Text("Log file")
                .sectionEyebrow()

            HStack(alignment: .top) {
                if logStatsLoaded {
                    VStack(alignment: .leading, spacing: DSSpace.s0) {
                        Text(logURL?.path ?? "(no log file)")
                            .font(.system(size: DSFont.Size.sm, design: .monospaced))
                            .lineLimit(2)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                        Text("\(ByteFormatting.string(logSize)) · \(logLines) lines")
                            .font(.system(size: DSFont.Size.sm))
                            .foregroundStyle(.secondary)
                    }
                } else {
                    LoadingRow(text: "Reading log file…")
                }
                Spacer()
                Button {
                    refreshTick &+= 1
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .pointerCursor()
            }

            HStack {
                Button {
                    if let url = logURL {
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    }
                } label: {
                    Label("Reveal in Finder", systemImage: "folder")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .pointerCursor()
                .disabled(logURL == nil)

                Button {
                    if let path = logURL?.path {
                        Pasteboard.copy(path)
                    }
                } label: {
                    Label("Copy Path", systemImage: "doc.on.doc")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .pointerCursor()
                .disabled(logURL == nil)

                // No confirmation: this is a DEBUG tool. Truncates the live log in
                // place (rotated logs are untouched), then refreshes the stats.
                Button(role: .destructive) {
                    Log.clearLogFile()
                    refreshTick &+= 1
                } label: {
                    Label("Clear Log", systemImage: "trash")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .pointerCursor()
            }

            HStack {
                Button { Log.debug("Debug test line from Debug tab", category: .devTools) } label: {
                    Text("Log .debug").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .pointerCursor()
                Button { Log.info("Info test line from Debug tab", category: .devTools) } label: {
                    Text("Log .info").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .pointerCursor()
                Button { Log.warn("Warn test line from Debug tab", category: .devTools) } label: {
                    Text("Log .warn").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .pointerCursor()
                Button { Log.error("Error test line from Debug tab", category: .devTools) } label: {
                    Text("Log .error").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .pointerCursor()
            }
        }
    }

    // MARK: - Notification Firehose

    /// Picker of every app notification name, a JSON editor for userInfo, and
    /// Post / Reset buttons.
    private var firehoseSection: some View {
        VStack(alignment: .leading, spacing: DSSpace.s2) {
            Text("Notification firehose")
                .sectionEyebrow()

            Text("Post any app notification with optional JSON userInfo.")
                .font(.system(size: DSFont.Size.sm))
                .foregroundStyle(.secondary)

            Picker("Name", selection: $selectedNotification) {
                ForEach(AppConstants.Notifications.allNames, id: \.self) { name in
                    Text(name).tag(name)
                }
            }
            .pickerStyle(.menu)

            TextEditor(text: $userInfoJSON)
                .font(.system(size: DSFont.Size.sm, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(DSSpace.s2)
                .frame(minHeight: 96, maxHeight: 160)
                .background(
                    RoundedRectangle(cornerRadius: DSRadius.sm)
                        .fill(Color(nsColor: .textBackgroundColor))
                )
                .clipShape(RoundedRectangle(cornerRadius: DSRadius.sm))
                .overlay(
                    RoundedRectangle(cornerRadius: DSRadius.sm)
                        .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
                )

            HStack {
                Button {
                    post()
                } label: {
                    Label("Post Notification", systemImage: "paperplane.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .pointerCursor()

                Button {
                    userInfoJSON = "{}"
                    postStatus = nil
                } label: {
                    Label("Reset", systemImage: "arrow.counterclockwise")
                }
                .buttonStyle(.bordered)
                .pointerCursor()
            }

            if let postStatus {
                Text(postStatus)
                    .font(.system(size: DSFont.Size.sm))
                    .foregroundStyle(postStatus.hasPrefix("Posted") ? DSColor.success : DSColor.error)
            }
        }
    }

    /// Posts `selectedNotification` on `NotificationCenter.default` with the parsed
    /// userInfo, and records the outcome in `postStatus`.
    ///
    /// The JSON must decode to an object (`[String: Any]`); an array or scalar is
    /// reported as "Invalid JSON" and nothing is posted. Observers receive raw
    /// JSON types (`NSNumber`, `String`, ...), so a handler that casts its
    /// userInfo to a richer type will see the cast fail rather than crash.
    private func post() {
        let trimmed = userInfoJSON.trimmingCharacters(in: .whitespacesAndNewlines)
        var userInfo: [AnyHashable: Any] = [:]
        if !trimmed.isEmpty, trimmed != "{}" {
            guard let data = trimmed.data(using: .utf8),
                  let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                postStatus = "Invalid JSON"
                return
            }
            userInfo = parsed
        }
        NotificationCenter.default.post(
            name: NSNotification.Name(selectedNotification),
            object: nil,
            userInfo: userInfo.isEmpty ? nil : userInfo
        )
        postStatus = "Posted \(selectedNotification)"
        Log.info("Posted notification \(selectedNotification) (dev)", category: .devTools)
    }
}

#Preview {
    DebugLogsAndEventsCard()
        .padding()
        .frame(width: 600)
}
#endif
