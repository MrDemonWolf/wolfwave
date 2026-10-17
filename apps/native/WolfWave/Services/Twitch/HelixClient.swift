//
//  HelixClient.swift
//  WolfWave
//
//  Created by Nathanial Henniges on 2026-05-28.
//  Copyright © 2026 MrDemonWolf, Inc. All rights reserved.
//

import Foundation

/// Wrapper around `HTTPClient` that knows how to talk to the Twitch Helix API.
///
/// Centralizes the auth header (`Authorization: Bearer …`, `Client-Id: …`),
/// JSON body encoding, status validation, and Helix-shaped error mapping so
/// service code does not rebuild the same `URLRequest` scaffolding at every
/// endpoint call site.
///
/// The type holds no mutable state and is trivially `Sendable`.
nonisolated struct HelixClient: Sendable {

    // MARK: - Types

    /// Credentials needed for a Helix call.
    ///
    /// `token` is the user OAuth access token (sent as `Bearer`), `clientID`
    /// the app's Twitch client ID (sent as `Client-Id`). Helix rejects a
    /// token minted for a different client ID, so the two must match.
    struct Credentials: Sendable {
        let token: String
        let clientID: String

        init(token: String, clientID: String) {
            self.token = token
            self.clientID = clientID
        }
    }

    /// Errors produced by Helix calls.
    enum HelixError: Error, LocalizedError, Equatable {
        /// The server returned a non-2xx status code. Includes the status code
        /// and the raw response body for diagnostics.
        case http(status: Int, body: String)
        /// The token was rejected (HTTP 401).
        case unauthorized(body: String)
        /// The endpoint is rate-limited (HTTP 429).
        case rateLimited(body: String)
        /// The response was missing or malformed.
        case malformedResponse
        /// Encoding the request body failed.
        case encodingFailed(message: String)
        /// JSON decoding of the response failed.
        case decodingFailed(message: String)
        /// The underlying transport (`URLSession`) failed.
        case transport(message: String)

        /// User-presentable text. Response bodies are clipped to 200
        /// characters so a large HTML error page can't flood a log line or
        /// an alert.
        var errorDescription: String? {
            switch self {
            case let .http(status, body):
                return "Twitch API error \(status): \(body.prefix(200))"
            case let .unauthorized(body):
                return "Twitch token rejected: \(body.prefix(200))"
            case let .rateLimited(body):
                return "Twitch rate limit hit: \(body.prefix(200))"
            case .malformedResponse:
                return "Unexpected response from Twitch."
            case let .encodingFailed(message):
                return "Failed to encode Helix request body: \(message)"
            case let .decodingFailed(message):
                return "Failed to decode Helix response: \(message)"
            case let .transport(message):
                return "Network error: \(message)"
            }
        }
    }

    // MARK: - Properties

    /// HTTP client used to perform the underlying request.
    let http: HTTPClient

    // MARK: - Init

    /// - Parameter http: Transport to send through. Tests inject a client
    ///   backed by a stubbed `URLSession`; production uses `.shared`.
    init(http: HTTPClient = .shared) {
        self.http = http
    }

    // MARK: - Typed Requests

    /// Performs a GET request and decodes the JSON response.
    ///
    /// - Parameters:
    ///   - url: Helix endpoint URL.
    ///   - credentials: Caller credentials.
    /// - Returns: A value of type `T` decoded from the response body.
    /// - Throws: `HelixError` on transport, status, or decoding failure.
    func get<T: Decodable>(
        url: URL,
        credentials: Credentials
    ) async throws -> T {
        let request = try makeRequest(
            url: url, method: "GET", credentials: credentials, body: nil)
        let (data, http) = try await send(request)
        try validate(http: http, data: data)
        return try decode(data: data)
    }

    /// Performs a POST request with a JSON body and decodes the response.
    ///
    /// - Parameters:
    ///   - url: Helix endpoint URL.
    ///   - credentials: Caller credentials.
    ///   - body: JSON object serialized with `JSONSerialization`.
    /// - Returns: A value of type `T` decoded (snake_case keys) from the response body.
    /// - Throws: `HelixError` on encoding, transport, status, or decoding failure.
    func post<T: Decodable>(
        url: URL,
        credentials: Credentials,
        body: [String: Any]
    ) async throws -> T {
        let request = try makeRequest(
            url: url, method: "POST", credentials: credentials, body: body)
        let (data, http) = try await send(request)
        try validate(http: http, data: data)
        return try decode(data: data)
    }

    // MARK: - Untyped (JSON Object) Requests

    /// Performs a request and returns the parsed JSON object dictionary.
    /// Use when the response shape is dynamic and strict `Decodable` typing
    /// isn't worth the boilerplate.
    ///
    /// - Parameters:
    ///   - requestTimeout: Overrides the request's timeout in seconds; `nil`
    ///     keeps the `URLRequest` default.
    /// - Returns: The top-level JSON object, or `nil` when the body is empty
    ///   (e.g. a 204) **or** when a 2xx body isn't a JSON object. Parse
    ///   failures are swallowed on purpose, so callers that need the payload
    ///   must treat `nil` as "no usable body", not only "no content".
    /// - Throws: `HelixError` on encoding, transport, or non-2xx status.
    @discardableResult
    func sendJSON(
        url: URL,
        method: String,
        credentials: Credentials,
        body: [String: Any]? = nil,
        requestTimeout: TimeInterval? = nil
    ) async throws -> [String: Any]? {
        var request = try makeRequest(
            url: url, method: method, credentials: credentials, body: body)
        if let requestTimeout {
            request.timeoutInterval = requestTimeout
        }
        let (data, http) = try await send(request)
        try validate(http: http, data: data)
        guard !data.isEmpty else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    /// Performs a request without status validation while retaining all HTTP
    /// response headers. Retry workers use this for server-directed backoff
    /// (`Retry-After`) without rebuilding Helix authentication requests.
    ///
    /// - Returns: The raw body and response, whatever the status code.
    /// - Throws: `HelixError` only for encoding or transport failures; any
    ///   status, including 401 and 429, is returned for the caller to branch on.
    func sendRawResponse(
        url: URL,
        method: String,
        credentials: Credentials,
        body: [String: Any]? = nil
    ) async throws -> (Data, HTTPURLResponse) {
        let request = try makeRequest(
            url: url, method: method, credentials: credentials, body: body)
        return try await send(request)
    }

    // MARK: - Request Construction

    /// Standard Helix headers: auth + client id + JSON content type + the
    /// shared default `User-Agent` (honest app identification).
    static func headers(for credentials: Credentials) -> [String: String] {
        HTTPClient.withDefaultUserAgent([
            "Authorization": "Bearer \(credentials.token)",
            "Client-Id": credentials.clientID,
            "Content-Type": "application/json"
        ])
    }

    /// Builds a Helix `URLRequest`: auth + client-id + JSON content-type headers
    /// plus a JSON-serialized body.
    ///
    /// Exposed `static` so call sites that need a custom send path (rate-limit
    /// header capture, bespoke status branching) reuse the exact same request
    /// construction instead of rebuilding the header loop and body serialization.
    ///
    /// - Throws: ``HelixError/encodingFailed(message:)`` when `body` isn't valid JSON.
    static func buildRequest(
        url: URL,
        method: String,
        credentials: Credentials,
        body: [String: Any]? = nil
    ) throws -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        for (key, value) in headers(for: credentials) {
            request.setValue(value, forHTTPHeaderField: key)
        }
        if let body {
            do {
                request.httpBody = try JSONSerialization.data(withJSONObject: body)
            } catch {
                throw HelixError.encodingFailed(message: error.localizedDescription)
            }
        }
        return request
    }

    // MARK: - Private Helpers

    /// Instance shim over ``buildRequest(url:method:credentials:body:)``.
    private func makeRequest(
        url: URL,
        method: String,
        credentials: Credentials,
        body: [String: Any]?
    ) throws -> URLRequest {
        try Self.buildRequest(url: url, method: method, credentials: credentials, body: body)
    }

    /// Sends through `HTTPClient` and translates its errors into `HelixError`
    /// so callers only ever see one error type. Status is not validated here.
    private func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do {
            return try await http.send(request)
        } catch let error as HTTPClient.HTTPError {
            switch error {
            case .invalidResponse:
                throw HelixError.malformedResponse
            case let .transport(underlying):
                throw HelixError.transport(message: underlying.localizedDescription)
            case let .decodingFailed(underlying):
                throw HelixError.decodingFailed(message: underlying.localizedDescription)
            case let .unexpectedStatus(status, body):
                throw mappedStatus(status, body: body)
            }
        } catch {
            throw HelixError.transport(message: error.localizedDescription)
        }
    }

    /// Throws the mapped `HelixError` for any non-2xx status.
    private func validate(http: HTTPURLResponse, data: Data) throws {
        let status = http.statusCode
        guard (200..<300).contains(status) else {
            throw mappedStatus(status, body: String(data: data, encoding: .utf8) ?? "")
        }
    }

    /// Maps a status to its Helix error: 401 and 429 get dedicated cases
    /// because callers react to them (re-auth, back off); everything else
    /// is a generic `.http`.
    private func mappedStatus(_ status: Int, body: String) -> HelixError {
        switch status {
        case 401: return .unauthorized(body: body)
        case 429: return .rateLimited(body: body)
        default: return .http(status: status, body: body)
        }
    }

    /// Decodes with the shared snake_case decoder (Helix keys are snake_case).
    private func decode<T: Decodable>(data: Data) throws -> T {
        do {
            return try JSONCoders.snakeCase.decode(T.self, from: data)
        } catch {
            throw HelixError.decodingFailed(message: error.localizedDescription)
        }
    }
}
