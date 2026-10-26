//
//  OnboardingPreferencesStepView.swift
//  WolfWave
//
//  Created by Nathanial Henniges on 2026-05-07.
//  Copyright © 2026 MrDemonWolf, Inc. All rights reserved.
//

import AppKit
import SwiftUI

/// Preferences step. Wire up the Mac-level conveniences (launch at login,
/// listening history) so the user doesn't have to hunt for them in Settings
/// later. The last step: its primary button reads Finish.
///
/// Each toggle posts its change notification itself, because writing the
/// preference alone does not start or stop the matching service.
struct OnboardingPreferencesStepView: View {

    // MARK: - Properties

    /// The `launchAtLogin` preference, owned by `OnboardingView`. Only written
    /// after `LaunchAtLoginService` accepts the change.
    @Binding var launchAtLogin: Bool
    /// Registration failure shown under the toggle, with a link to Login Items.
    /// Cleared by the next attempt that does not fail.
    @State private var launchAtLoginError: String?

    @AppStorage(AppConstants.UserDefaults.listeningHistoryEnabled)
    private var listeningHistoryEnabled = false

    @AppStorage(AppConstants.UserDefaults.iCloudSettingsSyncEnabled)
    private var iCloudSettingsSyncEnabled = false

    // MARK: - Body

    var body: some View {
        OnboardingStepScaffold(
            title: "Last few settings",
            description: "All off for now. Turn on what helps, then click Finish.",
            icon: {
                BrandTileGlyph.symbol("gearshape.fill", tint: Color.accentColor)
            },
            extras: {
                VStack(spacing: DSSpace.s2) {
                    OnboardingToggleCard(
                        icon: "power",
                        iconColor: .green,
                        title: "Start WolfWave at login",
                        subtitle: "WolfWave starts quietly in the menu bar.",
                        isOn: Binding(
                            get: { launchAtLogin },
                            set: { newValue in
                                // `.requiresApproval` still counts as opted-in; only a
                                // hard `.failure` leaves the toggle where it was.
                                let outcome = LaunchAtLoginService.setEnabled(newValue)
                                launchAtLoginError = outcome == .failure
                                    ? LaunchAtLoginService.registrationFailureMessage
                                    : nil
                                guard outcome != .failure else { return }
                                launchAtLogin = newValue
                            }
                        ),
                        accessibilityLabel: "Start WolfWave at login",
                        accessibilityIdentifier: "onboardingLaunchAtLoginToggle"
                    )

                    if let launchAtLoginError {
                        CalloutBanner(launchAtLoginError, style: .warning) {
                            Button("Open Login Items") {
                                LaunchAtLoginService.openLoginItemsSettings()
                            }
                            .buttonStyle(.borderedProminent)
                            .pointerCursor()
                        }
                    }

                    OnboardingToggleCard(
                        icon: "chart.bar.xaxis",
                        iconColor: .purple,
                        title: "Remember my listening history",
                        subtitle: "Stays on this Mac. Powers your top artists and stats.",
                        isOn: Binding(
                            get: { listeningHistoryEnabled },
                            set: { newValue in
                                listeningHistoryEnabled = newValue
                                NotificationCenter.default.postEnabled(
                                    .listeningHistorySettingChanged, enabled: newValue)
                            }
                        ),
                        accessibilityLabel: "Remember my listening history",
                        accessibilityIdentifier: "onboardingListeningHistoryToggle"
                    )

                    OnboardingToggleCard(
                        icon: "icloud.fill",
                        iconColor: .blue,
                        title: "Sync settings with iCloud",
                        subtitle: "Same settings on your other Macs. Sign-ins stay here.",
                        isOn: Binding(
                            get: { iCloudSettingsSyncEnabled },
                            set: { newValue in
                                iCloudSettingsSyncEnabled = newValue
                                NotificationCenter.default.postEnabled(
                                    .iCloudSettingsSyncSettingChanged, enabled: newValue)
                            }
                        ),
                        accessibilityLabel: "Sync settings with iCloud",
                        accessibilityIdentifier: "onboardingICloudSyncToggle"
                    )
                }
            }
        )
    }
}

// MARK: - Preview

#Preview {
    OnboardingPreferencesStepView(launchAtLogin: .constant(false))
        .frame(width: 600, height: 480)
}
