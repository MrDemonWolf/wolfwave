//
//  MusicPermissionRecheckButton.swift
//  WolfWave
//
//  Created by Nathanial Henniges on 2026-10-10.
//  Copyright © 2026 MrDemonWolf, Inc. All rights reserved.
//

import SwiftUI

/// Rechecks Automation access and reports the actual result, not elapsed time.
///
/// The button awaits the recheck through `AsyncActionButton`, so it shows a
/// spinner until the probe returns, then a one-line result underneath. A grant
/// shows no text: the caller is expected to react to the new state itself
/// (typically by hiding the banner this sits in).
struct MusicPermissionRecheckButton: View {

    // MARK: - Properties

    /// Runs the permission probe and returns what it found.
    var onTryAgain: () async -> MusicPermissionState
    /// Result line under the button; `nil` hides it.
    @State private var feedback: String?

    var body: some View {
        VStack(alignment: .leading, spacing: DSSpace.s2) {
            AsyncActionButton(title: "Try again", style: .borderless, showsSuccess: false) {
                // Clear the previous result first so a stale "Still off" isn't
                // shown next to the spinner while the new probe runs.
                feedback = nil
                feedback = await Self.recheckFeedback(using: onTryAgain)
            }
            .accessibilityHint("Rechecks whether Apple Music access is now on")

            if let feedback {
                Text(feedback)
                    .font(.system(size: DSFont.Size.sm))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Helpers

    /// Runs `recheck` and maps its result to the feedback line.
    ///
    /// `static` and closure-driven so tests can exercise the copy without
    /// rendering the view.
    ///
    /// - Parameter recheck: The permission probe.
    /// - Returns: The message for `.denied` or `.unknown`, or `nil` when access
    ///   was granted.
    static func recheckFeedback(using recheck: () async -> MusicPermissionState) async -> String? {
        switch await recheck() {
        case .denied: "Still off. In Automation, turn on Music under WolfWave."
        case .unknown: "Open Music, then try again."
        case .granted: nil
        }
    }
}
