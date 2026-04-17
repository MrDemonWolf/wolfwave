//
//  TwitchAPIRequest.swift
//  wolfwave
//
//  Created by MrDemonWolf, Inc. on 1/17/26.
//

import Foundation

/// Builders for authenticated Twitch Helix API requests.
///
/// Centralizes the `Bearer <token>` + `Client-ID` header pattern used by every
/// Helix call. Callers still own response decoding and endpoint-specific error
/// handling (error shapes differ per endpoint).
enum TwitchAPIRequest {

    /// Builds a Helix request carrying `Authorization: Bearer <token>` and `Client-ID`.
    ///
    /// - Parameters:
    ///   - url: Fully-resolved endpoint URL.
    ///   - method: HTTP method (`"GET"`, `"POST"`, `"DELETE"`, etc.). Defaults to `"GET"`.
    ///   - token: OAuth user access token (without the `Bearer ` prefix).
    ///   - clientID: Twitch application client ID.
    ///   - jsonBody: Optional JSON body; if provided, sets `Content-Type: application/json`
    ///     and `httpBody` to the serialized data.
    /// - Returns: Configured `URLRequest` ready for `URLSession.data(for:)`.
    static func helix(
        url: URL,
        method: String = "GET",
        token: String,
        clientID: String,
        jsonBody: Data? = nil
    ) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(clientID, forHTTPHeaderField: "Client-ID")
        if let jsonBody {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = jsonBody
        }
        return request
    }

    /// Builds a request to the OAuth2 `/validate` endpoint using `OAuth <token>`
    /// (Twitch requires this scheme rather than `Bearer` for validate).
    static func validate(url: URL, token: String) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("OAuth \(token)", forHTTPHeaderField: "Authorization")
        return request
    }
}
