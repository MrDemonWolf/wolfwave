//
//  SettingsSidebarView.swift
//  WolfWave
//
//  Created by Nathanial Henniges on 2026-06-03.
//  Copyright © 2026 MrDemonWolf, Inc. All rights reserved.
//

import SwiftUI

/// Native macOS settings sidebar: a plain `List(selection:)` of `Label` rows
/// grouped into `Section`s, rendered with `.listStyle(.sidebar)`.
///
/// This is deliberately stock SwiftUI. No custom row backgrounds, hover fills,
/// selection pills, or brand header. The system draws the standard sidebar
/// selection highlight (the rounded accent capsule), supplies the uppercase
/// secondary section headers, tints icons on selection, and handles keyboard
/// arrow navigation and VoiceOver semantics. The result matches Apple's own
/// sidebars (Finder, Notes, the Landmarks sample): the native look, with the
/// `NavigationSplitView` sidebar toggle owned by the title bar.
///
/// Anything that overrides `listRowBackground` here will suppress the native
/// selection highlight; leave the rows stock.
struct SettingsSidebarView: View {
    // MARK: - Properties

    /// Currently selected section. Bound to the parent `NavigationSplitView`.
    @Binding var selection: SettingsView.SettingsSection

    #if DEBUG
    /// The Debug pane's selected tool. Its tools are sub-rows under the Debug
    /// row here, so the pane needs no navigation of its own.
    @Binding var debugTool: DebugSection

    /// Whether the Debug row shows its tools. Opens when Debug becomes the
    /// pane, so the selected tool's row is always visible to carry the
    /// highlight; the arrow closes it again.
    @State private var debugExpanded = false
    #endif

    // MARK: - Selection

    /// One selectable sidebar row: a pane, or (Debug builds) a Debug tool.
    private enum Item: Hashable {
        case pane(SettingsView.SettingsSection)
        #if DEBUG
        case debugTool(DebugSection)
        #endif
    }

    /// Maps the pane (and Debug tool) bindings onto the one value
    /// `List(selection:)` needs. While Debug is the pane, the selected row is
    /// its current tool, so clicking Debug lands the highlight on a sub-row.
    private var itemSelection: Binding<Item> {
        Binding {
            #if DEBUG
            if selection == .debug { return .debugTool(debugTool) }
            #endif
            return .pane(selection)
        } set: { item in
            switch item {
            case .pane(let section):
                selection = section
            #if DEBUG
            case .debugTool(let tool):
                debugTool = tool
                selection = .debug
            #endif
            }
        }
    }

    /// Grouped sidebar layout (optional header + member sections). Supplied by
    /// `SettingsView.sidebarGroups` so the order/headers stay defined in one place.
    let groups: [(title: String?, sections: [SettingsView.SettingsSection])]

    // MARK: - Body

    var body: some View {
        List(selection: itemSelection) {
            ForEach(groups, id: \.sections) { group in
                // Named groups get the native uppercase/secondary section header
                // from `.sidebar`. The title-less group (General) renders as a
                // plain section so it sits flush at the top with no header gap.
                if let title = group.title {
                    Section {
                        rows(for: group.sections)
                    } header: {
                        Text(title).sectionEyebrow()
                    }
                } else {
                    Section { rows(for: group.sections) }
                }
            }
        }
        .listStyle(.sidebar)
        #if DEBUG
        .onChange(of: selection, initial: true) { _, section in
            if section == .debug { debugExpanded = true }
        }
        #endif
        // Keep labels readable when native layout overrides the column-width preference.
        .frame(width: AppConstants.SettingsUI.sidebarWidth)
        .accessibilityIdentifier("settings.sidebar")
    }

    /// Selectable navigation rows for one group. Each row is a stock `Label`
    /// tagged with its section so `List(selection:)` drives the binding.
    private func rows(for sections: [SettingsView.SettingsSection]) -> some View {
        ForEach(sections) { section in
            #if DEBUG
            if section == .debug {
                debugDisclosure
            } else {
                paneRow(section)
            }
            #else
            paneRow(section)
            #endif
        }
    }

    /// One selectable pane row.
    private func paneRow(_ section: SettingsView.SettingsSection) -> some View {
        SettingsSidebarRow(section: section)
            .tag(Item.pane(section))
            // Stable handle for the UI tests. The visible title is not one:
            // several pane bodies repeat their own section's name, so a
            // label query would match the sidebar row and the content both.
            .accessibilityIdentifier("settings.sidebar.\(section.rawValue)")
    }

    #if DEBUG
    /// The Debug row as a stock `DisclosureGroup`: the system draws the
    /// disclosure arrow and indents the tools under it, the same outline
    /// Finder and Xcode sidebars use. It replaces the second list the Debug
    /// pane used to draw beside this one (two sidebars, two materials).
    ///
    /// Nothing here is hand-styled. No manual indent, no custom chevron: both
    /// would drift from the system's metrics.
    private var debugDisclosure: some View {
        DisclosureGroup(isExpanded: $debugExpanded) {
            ForEach(DebugSection.railGroups.flatMap(\.sections), id: \.self) { tool in
                Label(tool.title, systemImage: tool.icon)
                    .tag(Item.debugTool(tool))
                    .accessibilityIdentifier("debugNav.\(tool.rawValue)")
            }
        } label: {
            paneRow(.debug)
        }
    }
    #endif
}

// MARK: - Sidebar Row

/// One navigation row: a native `Label` pairing the section title with an icon.
/// SF Symbol sections use the symbol directly; brand sections (Twitch / Discord)
/// supply a template image so the system tints it like a symbol: monochrome at
/// rest, white on the selection capsule.
private struct SettingsSidebarRow: View {
    /// The pane this row selects; supplies the title and icon.
    let section: SettingsView.SettingsSection

    var body: some View {
        Label {
            Text(section.rawValue)
        } icon: {
            if let brandIcon = section.brandIcon {
                Image(brandIcon)
                    .renderingMode(.template)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 16, height: 16)
            } else {
                Image(systemName: section.systemIcon)
            }
        }
        // Kebab-cased title. Note the row's caller (`rows(for:)`) applies its own
        // `settings.sidebar.<title>` identifier afterwards; UI tests query that one.
        .accessibilityIdentifier(section.rawValue.replacingOccurrences(of: " ", with: "-").lowercased())
    }
}
