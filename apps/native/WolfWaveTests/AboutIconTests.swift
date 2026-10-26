//
//  AboutIconTests.swift
//  WolfWave
//
//  Created by Nathanial Henniges on 2026-10-25.
//  Copyright © 2026 MrDemonWolf, Inc. All rights reserved.
//

import AppKit
import Testing
@testable import WolfWave

@MainActor
struct AboutIconTests {
    @Test("About artwork matches the packaged application identity")
    func packagedArtworkExists() throws {
        let iconName = try #require(Bundle.main.object(forInfoDictionaryKey: "CFBundleIconName") as? String)
        #expect(AboutCopy.iconAssetName == "About-\(iconName)")
        #expect(Bundle.main.image(forResource: AboutCopy.iconAssetName) != nil)
    }
}
