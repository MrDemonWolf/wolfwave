//
//  MusicPermissionRecheckButton.swift
//  WolfWave
//
//  Created by Nathanial Henniges on 2026-10-08.
//  Copyright © 2026 MrDemonWolf, Inc. All rights reserved.
//

import SwiftUI

/// Rechecks Automation access and reports the actual result, not elapsed time.
struct MusicPermissionRecheckButton: View {
    var onTryAgain: () async -> MusicPermissionState
    @State private var feedback: String?

    var body: some View {
        VStack(alignment: .leading, spacing: DSSpace.s2) {
            AsyncActionButton(title: "Try again", style: .borderless, showsSuccess: false) {
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

    static func recheckFeedback(using recheck: () async -> MusicPermissionState) async -> String? {
        switch await recheck() {
        case .denied: "Still off. In Automation, turn on Music under WolfWave."
        case .unknown: "Open Music, then try again."
        case .granted: nil
        }
    }
}
