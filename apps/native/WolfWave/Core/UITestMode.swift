//
//  UITestMode.swift
//  WolfWave
//
//  Created by Nathanial Henniges on 2026-08-17.
//  Copyright © 2026 MrDemonWolf, Inc. All rights reserved.
//

import Foundation

/// Whether this launch is being driven by the `WolfWaveUITests` XCUITest bundle.
///
/// Sibling of ``WolfWaveApp/isRunningTests``, and necessary because that flag
/// cannot see a UI test. In a UI test the app runs in its *own* process:
/// `XCTest.framework` is never loaded into it and none of the `XCTest*`
/// environment variables are set, so every isolation seam keyed on
/// `isRunningTests` (``DefaultsStore/store``, ``KeychainService/backend``)
/// would resolve to the live ones. A UI test toggling a setting would then edit
/// the developer's real `com.mrdemonwolf.wolfwave.dev` domain, which is the
/// exact corruption `DefaultsStore` was introduced to prevent.
///
/// The signal is an environment variable rather than a launch argument on
/// purpose: `UserDefaults` parses `-flag value` launch arguments into the
/// argument domain, so a bare `-flag` is a defaults key with confusing
/// semantics. `launchEnvironment` touches nothing.
///
/// Release builds compile the switch out entirely (`isActive` is a constant
/// `false` and none of the keys exist in the binary), so setting
/// `WOLFWAVE_UI_TEST=1` on a shipped app cannot redirect it to throwaway
/// storage. `make test-ui` always drives the Debug app.
nonisolated enum UITestMode {

    #if DEBUG
    /// Set on `XCUIApplication.launchEnvironment` by the UI test bundle.
    static let environmentKey = "WOLFWAVE_UI_TEST"

    /// True when the app was launched by the UI test bundle.
    static let isActive = ProcessInfo.processInfo.environment[environmentKey] == "1"

    /// Set to `"1"` by a UI test that wants to land straight in the app rather
    /// than in the wizard. Every launch starts from a wiped suite, so without it
    /// each test would have to walk onboarding before reaching its subject.
    static let skipOnboardingKey = "WOLFWAVE_UI_TEST_ONBOARDED"

    /// Set to `"1"` to suppress the What's New window. A version-gated window
    /// appearing over the app mid-test is a focus race, not a finding.
    static let suppressWhatsNewKey = "WOLFWAVE_UI_TEST_NO_WHATS_NEW"

    /// Set to `"light"` or `"dark"` to pin the app appearance, so a screenshot
    /// capture can render both appearances on one machine. Written into the
    /// isolated suite as the stored appearance preference, which the normal
    /// launch path then applies; any other value is ignored.
    static let appearanceKey = "WOLFWAVE_UI_TEST_APPEARANCE"

    /// Set to `"1"` to keep the onboarding completion screen up until Done,
    /// so a screenshot capture is not racing its auto-dismiss timer.
    static let holdCompletionKey = "WOLFWAVE_UI_TEST_HOLD_COMPLETION"

    /// True when the UI test asked to keep the completion screen up.
    static var holdsCompletion: Bool {
        isActive && ProcessInfo.processInfo.environment[holdCompletionKey] == "1"
    }

    /// True when the UI test asked to start past onboarding.
    static var startsOnboarded: Bool {
        isActive && ProcessInfo.processInfo.environment[skipOnboardingKey] == "1"
    }

    /// True when the UI test asked to suppress What's New.
    static var suppressesWhatsNew: Bool {
        isActive && ProcessInfo.processInfo.environment[suppressWhatsNewKey] == "1"
    }

    /// The appearance the UI test pinned, or `nil` to follow the system.
    static var requestedAppearance: String? {
        guard isActive, let value = ProcessInfo.processInfo.environment[appearanceKey] else { return nil }
        return [AppConstants.Appearance.light, AppConstants.Appearance.dark].contains(value) ? value : nil
    }
    #else
    /// Release builds never run under the UI test bundle.
    static let isActive = false

    /// Always `false` in Release.
    static var startsOnboarded: Bool { false }

    /// Always `false` in Release.
    static var suppressesWhatsNew: Bool { false }

    /// Always `nil` in Release.
    static var requestedAppearance: String? { nil }

    /// Always `false` in Release.
    static var holdsCompletion: Bool { false }
    #endif

    /// True when *any* test harness owns this process: the hosted unit bundle
    /// (in-process) or a UI test (out-of-process). Storage seams branch on this,
    /// never on `isRunningTests` alone.
    static var isUnderTestHarness: Bool { WolfWaveApp.isRunningTests || isActive }

    /// Writes the requested starting state into the (already wiped) isolated
    /// suite. Must run before anything reads onboarding state. No-op outside a
    /// UI test, so a normal launch never reaches the write.
    static func seedRequestedState() {
        if let appearance = requestedAppearance {
            DefaultsStore.store.set(appearance, forKey: AppConstants.UserDefaults.appearancePreference)
        }
        guard startsOnboarded else { return }
        DefaultsStore.store.set(true, forKey: AppConstants.UserDefaults.hasCompletedOnboarding)
    }
}
