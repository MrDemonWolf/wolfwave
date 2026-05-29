//
//  main.swift
//  WolfWaveOverlayServer (XPC Service)
//
//  Copyright © 2026 MrDemonWolf, Inc. All rights reserved.
//
//  The overlay WebSocket + Widget HTTP server runs here, isolated from the main
//  app. All logic lives in WolfWaveOverlayKit; this is just the entry point.
//  `OverlayServiceMain.start()` resumes the NSXPCListener service run loop and
//  does not return.
//

import WolfWaveOverlayKit

OverlayServiceMain.start()
