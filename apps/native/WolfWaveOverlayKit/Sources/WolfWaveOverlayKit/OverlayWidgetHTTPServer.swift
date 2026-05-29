//
//  OverlayWidgetHTTPServer.swift
//  WolfWaveOverlayKit
//
//  Copyright © 2026 MrDemonWolf, Inc. All rights reserved.
//
//  Port of the app's `WidgetHTTPService`. Differences after the move:
//   - Reads assets from an injected `resourceBundle` (the .xpc's Bundle.main, or
//     a test bundle) instead of the app's `Bundle.main`.
//   - Favicon is served from a bundled `favicon.png` if present (no AppKit /
//     NSImage / asset-catalog dependency); 404 otherwise.
//   - `os.Logger` instead of the app `Log`.
//   - `WebSocketTokenRules.isValid` instead of `WebSocketAuthToken.isValid`.
//

import Foundation
import Network
import os

/// Serves the bundled `widget.html` over plain HTTP/1.1. Token injection runs
/// only for loopback peers (see `serveWidget`).
public final class OverlayWidgetHTTPServer: @unchecked Sendable {

    // MARK: - Routing (pure, testable)

    public enum Route: Equatable {
        case widget
        case tokensJS
        case favicon
        case notFound
    }

    /// Parses an HTTP request blob and resolves the route. Pure — no socket, so
    /// unit tests can exercise it directly.
    public static func route(forRequest requestData: Data) -> Route {
        let requestString = String(data: requestData, encoding: .utf8) ?? ""
        let firstLine = requestString.components(separatedBy: "\r\n").first ?? ""
        let parts = firstLine.components(separatedBy: " ")
        let method = parts.count > 0 ? parts[0] : ""
        let rawPath = parts.count > 1 ? parts[1] : ""
        let path = rawPath.components(separatedBy: "?").first ?? rawPath

        guard method == "GET" else { return .notFound }
        if path == "/" || path.isEmpty { return .widget }
        if path == "/widget-tokens.generated.js" { return .tokensJS }
        if path == "/favicon.ico" || path == "/favicon.png" { return .favicon }
        return .notFound
    }

    /// Performs loopback-gated token substitution + token-JS inlining on the raw
    /// `widget.html`. Pure — exposed for tests.
    public static func renderWidgetHTML(
        rawHTML: String,
        tokensJS: String?,
        token: String?,
        isLoopback: Bool
    ) -> String {
        var rendered: String
        if isLoopback, let token, WebSocketTokenRules.isValid(token) {
            rendered = rawHTML.replacingOccurrences(of: tokenPlaceholder, with: token)
        } else {
            rendered = rawHTML
        }
        if let tokensJS {
            let inlined = "<script>\n" + tokensJS + "\n</script>"
            rendered = rendered.replacingOccurrences(of: tokensScriptTag, with: inlined)
        }
        return rendered
    }

    // MARK: - Properties

    private let log = Logger(subsystem: OverlayConstants.logSubsystem, category: "WidgetHTTP")
    private let port: UInt16
    private let authToken: String?
    private let resourceBundle: Bundle
    private var listener: NWListener?
    private let queue = DispatchQueue(label: OverlayConstants.widgetHTTPQueueLabel, qos: .utility)

    private static let tokenPlaceholder = "__WOLFWAVE_TOKEN__"
    private static let tokensScriptTag = "<script src=\"widget-tokens.generated.js\"></script>"

    // MARK: - Init

    public init(port: UInt16, authToken: String?, resourceBundle: Bundle) {
        self.port = port
        self.authToken = authToken
        self.resourceBundle = resourceBundle
    }

    // Last reference at dealloc, so no other thread races the listener here.
    deinit { listener?.cancel() }

    // MARK: - Lifecycle

    // `listener` is mutated only on `queue` (its own callbacks run there too), so
    // all reads/writes are confined to one serial executor — no data race with
    // the `.failed` callback that nils it out.
    public func start() {
        queue.async { [weak self] in
            guard let self, self.listener == nil else { return }

            let parameters = NWParameters.tcp
            guard let nwPort = NWEndpoint.Port(rawValue: self.port) else {
                self.log.error("Invalid port \(self.port)")
                return
            }
            do {
                self.listener = try NWListener(using: parameters, on: nwPort)
            } catch {
                self.log.error("Failed to create listener: \(error.localizedDescription)")
                return
            }

            self.listener?.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    self.log.info("Listening on port \(self.port)")
                case .failed(let error):
                    self.log.error("Listener failed: \(error.localizedDescription)")
                    self.listener = nil
                default:
                    break
                }
            }
            self.listener?.newConnectionHandler = { [weak self] connection in
                self?.handleConnection(connection)
            }
            self.listener?.start(queue: self.queue)
        }
    }

    public func stop() {
        queue.async { [weak self] in
            self?.listener?.cancel()
            self?.listener = nil
            self?.log.info("Server stopped")
        }
    }

    // MARK: - Connection Handling

    private func handleConnection(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, _, error in
            guard let self else { connection.cancel(); return }
            guard let data, !data.isEmpty, error == nil else { connection.cancel(); return }
            switch Self.route(forRequest: data) {
            case .widget: self.serveWidget(to: connection)
            case .tokensJS: self.serveTokensJS(to: connection)
            case .favicon: self.serveFavicon(to: connection)
            case .notFound: self.send404(to: connection)
            }
        }
    }

    // MARK: - Responses

    private func serveWidget(to connection: NWConnection) {
        guard let url = resourceBundle.url(forResource: "widget", withExtension: "html"),
              let raw = try? String(contentsOf: url, encoding: .utf8) else {
            log.error("widget.html not found in bundle")
            send404(to: connection)
            return
        }

        let isLoopback = Self.isLoopbackPeer(connection)
        if isLoopback, let token = authToken, !WebSocketTokenRules.isValid(token) {
            log.warning("Refusing to inject non-hex auth token into widget.html")
        }

        var tokensJS: String?
        if let tokensURL = resourceBundle.url(forResource: "widget-tokens.generated", withExtension: "js") {
            tokensJS = try? String(contentsOf: tokensURL, encoding: .utf8)
        }
        if tokensJS == nil {
            log.warning("widget-tokens.generated.js not found — falling back to external <script src>")
        }

        let rendered = Self.renderWidgetHTML(
            rawHTML: raw,
            tokensJS: tokensJS,
            token: authToken,
            isLoopback: isLoopback
        )
        let body = Data(rendered.utf8)
        sendHTTP(to: connection, contentType: "text/html; charset=utf-8", body: body)
    }

    private func serveTokensJS(to connection: NWConnection) {
        guard let url = resourceBundle.url(forResource: "widget-tokens.generated", withExtension: "js"),
              let body = try? Data(contentsOf: url) else {
            log.error("widget-tokens.generated.js not found in bundle")
            send404(to: connection)
            return
        }
        sendHTTP(
            to: connection,
            contentType: "application/javascript; charset=utf-8",
            body: body,
            extraHeaders: "Cache-Control: no-cache\r\n"
        )
    }

    private func serveFavicon(to connection: NWConnection) {
        guard let url = resourceBundle.url(forResource: "favicon", withExtension: "png"),
              let body = try? Data(contentsOf: url) else {
            send404(to: connection)
            return
        }
        sendHTTP(
            to: connection,
            contentType: "image/png",
            body: body,
            extraHeaders: "Cache-Control: public, max-age=86400\r\n"
        )
    }

    private func sendHTTP(
        to connection: NWConnection,
        contentType: String,
        body: Data,
        extraHeaders: String = ""
    ) {
        let header = "HTTP/1.1 200 OK\r\n" +
            "Content-Type: \(contentType)\r\n" +
            "Content-Length: \(body.count)\r\n" +
            extraHeaders +
            "Connection: close\r\n\r\n"
        var response = Data(header.utf8)
        response.append(body)
        connection.send(content: response, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private func send404(to connection: NWConnection) {
        let body = "Not Found"
        let response = "HTTP/1.1 404 Not Found\r\n" +
            "Content-Type: text/plain\r\n" +
            "Content-Length: \(body.utf8.count)\r\n" +
            "Connection: close\r\n\r\n" + body
        connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    // MARK: - Peer Inspection

    private static func isLoopbackPeer(_ connection: NWConnection) -> Bool {
        switch connection.endpoint {
        case .hostPort(let host, _):
            switch host {
            case .ipv4(let addr): return addr.isLoopback
            case .ipv6(let addr): return addr.isLoopback
            case .name(let name, _): return name == "localhost"
            @unknown default: return false
            }
        default:
            return false
        }
    }
}
