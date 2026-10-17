//
//  TwitchDeviceAuth+TokenParsing.swift
//  WolfWave
//
//  Created by Nathanial Henniges on 2026-10-16.
//  Copyright © 2026 MrDemonWolf, Inc. All rights reserved.
//

import Foundation

/// Pure parsing of Twitch OAuth token response bodies, shared by the
/// device-code poll and the refresh-token grant.
nonisolated extension TwitchDeviceAuth {

    // MARK: - Token Parsing (nonisolated, pure, testable)

    /// Parses a Twitch OAuth token response body into a `TwitchTokenResponse`.
    ///
    /// Returns `nil` when the body is not a JSON object or lacks a non-empty
    /// `access_token`. `refresh_token` and `expires_in` are optional.
    nonisolated static func parseTokenResponse(_ data: Data) -> TwitchTokenResponse? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let accessToken = json["access_token"] as? String,
              !accessToken.isEmpty else {
            return nil
        }
        let refreshToken = (json["refresh_token"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let expiresIn = json["expires_in"] as? Int
        return TwitchTokenResponse(
            accessToken: accessToken, refreshToken: refreshToken, expiresIn: expiresIn)
    }

    /// Device-code and refresh grants are durable only when Twitch rotates a
    /// non-empty refresh token alongside the access token. Keeping this guard
    /// separate preserves the generic parser for diagnostics while preventing
    /// access-only 2xx responses from becoming a four-hour false success.
    nonisolated static func parseRotatingTokenResponse(_ data: Data) -> TwitchTokenResponse? {
        guard let response = parseTokenResponse(data), response.refreshToken != nil else {
            return nil
        }
        return response
    }
}
