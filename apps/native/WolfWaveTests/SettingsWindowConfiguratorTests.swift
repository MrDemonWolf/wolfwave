//
//  SettingsWindowConfiguratorTests.swift
//  WolfWave
//
//  Created by Nathanial Henniges on 2026-10-10.
//  Copyright © 2026 MrDemonWolf, Inc. All rights reserved.
//

import AppKit
import SwiftUI
import Testing
@testable import WolfWave

@MainActor
struct SettingsWindowConfiguratorTests {
    @Test("Restored sidebar width is repaired only once per window")
    func initialWidthRepairDoesNotFightLaterLayout() {
        let (window, split) = makeWindow(sidebarWidth: 160)
        let coordinator = SettingsWindowConfigurator.Coordinator()

        coordinator.configure(window, visibility: .all)
        #expect(abs(split.arrangedSubviews[0].frame.width - AppConstants.SettingsUI.sidebarWidth) < 1)
        #expect(split.autosaveName == nil)
        #expect(window.titleVisibility == .hidden)
        #expect(window.titlebarAppearsTransparent)

        split.setPosition(100, ofDividerAt: 0)
        window.titleVisibility = .visible
        window.titlebarAppearsTransparent = false
        coordinator.configure(window, visibility: .all)
        #expect(abs(split.arrangedSubviews[0].frame.width - 100) < 1)
        #expect(window.titleVisibility == .hidden)
        #expect(window.titlebarAppearsTransparent)
    }

    @Test("An already-correct width also completes the initial repair")
    func correctInitialWidthIsNotRepinnedLater() {
        let (window, split) = makeWindow(sidebarWidth: AppConstants.SettingsUI.sidebarWidth)
        let coordinator = SettingsWindowConfigurator.Coordinator()
        coordinator.configure(window, visibility: .all)

        split.setPosition(100, ofDividerAt: 0)
        coordinator.configure(window, visibility: .all)
        #expect(abs(split.arrangedSubviews[0].frame.width - 100) < 1)
    }

    @Test("A hidden sidebar repairs only on its first visible layout", arguments: [CGFloat(0), CGFloat(160)])
    func hiddenSidebarWaitsForFirstVisibleLayout(initialWidth: CGFloat) {
        let (window, split) = makeWindow(sidebarWidth: initialWidth)
        let coordinator = SettingsWindowConfigurator.Coordinator()
        coordinator.configure(window, visibility: .detailOnly)
        #expect(abs(split.arrangedSubviews[0].frame.width - initialWidth) < 1)

        split.setPosition(160, ofDividerAt: 0)
        coordinator.configure(window, visibility: .all)
        #expect(abs(split.arrangedSubviews[0].frame.width - AppConstants.SettingsUI.sidebarWidth) < 1)
    }

    @Test("Missing attachment retries and a different window repairs independently")
    func repairsEachHostingWindow() {
        let coordinator = SettingsWindowConfigurator.Coordinator()
        coordinator.configure(nil, visibility: .all)
        let (firstWindow, firstSplit) = makeWindow(sidebarWidth: 160)
        firstWindow.contentView = NSView(frame: firstSplit.frame)
        coordinator.configure(firstWindow, visibility: .all)
        firstWindow.contentView = firstSplit
        coordinator.configure(firstWindow, visibility: .all)
        #expect(abs(firstSplit.arrangedSubviews[0].frame.width - AppConstants.SettingsUI.sidebarWidth) < 1)

        let (nextWindow, split) = makeWindow(sidebarWidth: 140)
        coordinator.configure(nextWindow, visibility: .all)
        #expect(abs(split.arrangedSubviews[0].frame.width - AppConstants.SettingsUI.sidebarWidth) < 1)
    }

    private func makeWindow(sidebarWidth: CGFloat) -> (NSWindow, NSSplitView) {
        let frame = NSRect(x: 0, y: 0, width: 900, height: 600)
        let window = NSWindow(contentRect: frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let split = NSSplitView(frame: frame)
        split.isVertical = true
        split.addArrangedSubview(NSView(frame: frame))
        split.addArrangedSubview(NSView(frame: frame))
        window.contentView = split
        split.adjustSubviews()
        split.setPosition(sidebarWidth, ofDividerAt: 0)
        return (window, split)
    }
}
