//
//  WebSocketServerService+Lifecycle.swift
//  WolfWave
//
//  Created by Nathanial Henniges on 2026-10-16.
//  Copyright © 2026 MrDemonWolf, Inc. All rights reserved.
//

import Foundation
import Network

/// Listener lifecycle for ``WebSocketServerService``: TCP parameters,
/// start, stop, listener-state handling, and the retry after a failure.
extension WebSocketServerService {

    // MARK: - Server Lifecycle

    /// TCP parameters with keepalive (30 s idle, then 3 probes 10 s apart) so a
    /// peer that vanished without a FIN (sleeping laptop, unplugged OBS box)
    /// is detected in about a minute instead of lingering as a client.
    nonisolated static func makeTCPParameters() -> NWParameters {
        let tcp = NWProtocolTCP.Options()
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 30
        tcp.keepaliveInterval = 10
        tcp.keepaliveCount = 3
        return NWParameters(tls: nil, tcp: tcp)
    }

    /// Runs an authorized command through the installed handler.
    ///
    /// Authorization (control role, loopback peer) is checked by
    /// `receiveMessage` before this is reached; this only dispatches.
    /// - Returns: The handler's ack, or `"unavailable"` when none is installed.
    func executeCommand(_ command: StreamDeckCommand) async -> CommandAck {
        guard let onCommand else { return .failure(command.action.rawValue, "unavailable") }
        return await onCommand(command)
    }

    /// Brings up the `NWListener` on the configured port and wires state and
    /// connection callbacks. Network.framework callbacks fire on `networkQueue`
    /// and hop back into the actor.
    func startServer() {
        guard listener == nil else { return }

        listenerGeneration &+= 1
        let generation = listenerGeneration

        transition(to: .starting)

        let parameters = Self.makeTCPParameters()
        let wsOptions = NWProtocolWebSocket.Options()
        wsOptions.autoReplyPing = true
        wsOptions.maximumMessageSize = Self.maximumInboundMessageSize

        // Resolve an explicit role during the handshake. The selected
        // subprotocol is validated again when the connection becomes ready.
        // The tokens are captured by value: this handler runs on `networkQueue`
        // and cannot read actor state, and a token change restarts the
        // listener anyway.
        let expectedOverlayToken = overlayToken
        let expectedControlToken = controlToken
        wsOptions.setClientRequestHandler(networkQueue) { subprotocols, _ in
            let role = WebSocketAuthToken.authenticationRole(
                overlayToken: expectedOverlayToken,
                controlToken: expectedControlToken,
                offeredSubprotocols: subprotocols
            )
            if let role {
                // Echo back the exact credential that matched. The `?? first`
                // branch is only reachable with no tokens (legacy test init).
                let token = role == .overlay ? expectedOverlayToken : expectedControlToken
                let selected = token.map {
                    WebSocketAuthToken.expectedSubprotocol(for: $0, role: role)
                } ?? subprotocols.first
                return NWProtocolWebSocket.Response(
                    status: .accept,
                    subprotocol: selected,
                    additionalHeaders: nil
                )
            }
            Log.info(
                "WebSocketServerService: Rejecting unauthenticated client (offered \(subprotocols.count) subprotocol(s))",
                category: .websocket
            )
            return NWProtocolWebSocket.Response(
                status: .reject,
                subprotocol: nil,
                additionalHeaders: nil
            )
        }

        parameters.defaultProtocolStack.applicationProtocols.insert(wsOptions, at: 0)

        do {
            guard let nwPort = NWEndpoint.Port(rawValue: port) else {
                Log.error("WebSocketServerService: Invalid port \(port)", category: .websocket)
                transition(to: .error)
                return
            }
            listener = try NWListener(using: parameters, on: nwPort)
        } catch {
            Log.error("WebSocketServerService: Failed to create listener: \(error)", category: .websocket)
            transition(to: .error)
            scheduleRetry()
            return
        }

        listener?.stateUpdateHandler = { [weak self] newState in
            guard let self else { return }
            Task {
                await self.handleListenerState(
                    newState,
                    generation: generation)
            }
        }

        listener?.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            Task {
                await self.handleNewConnection(
                    connection,
                    listenerGeneration: generation)
            }
        }

        listener?.start(queue: networkQueue)

        // The widget server starts alongside the listener, before it reports
        // `.listening`; it has its own bind and retry handling.
        if FeatureFlags.widgetHTTPEnabled {
            let resolvedPort = Preferences.resolvedWidgetPort
            widgetHTTPPort = resolvedPort
            widgetHTTP = WidgetHTTPService(port: resolvedPort, overlayToken: overlayToken)
            widgetHTTP?.start()
        }
    }

    /// Handles `NWListener.stateUpdateHandler` transitions inside the actor.
    ///
    /// On `.failed` this tears down like `stopServer()` (widget server, progress
    /// timer, every client) but ends in `.error` and schedules a retry.
    private func handleListenerState(
        _ newState: NWListener.State,
        generation: UInt64
    ) {
        guard generation == listenerGeneration else { return }
        switch newState {
        case .ready:
            Log.info("WebSocketServerService: Listening on port \(port)", category: .websocket)
            transition(to: .listening)
        case .failed(let error):
            Log.error("WebSocketServerService: Listener failed: \(error)", category: .websocket)
            listenerGeneration &+= 1
            listener?.stateUpdateHandler = nil
            listener?.newConnectionHandler = nil
            listener?.cancel()
            listener = nil
            widgetHTTP?.stop()
            widgetHTTP = nil
            widgetHTTPPort = nil
            stopProgressTimer()
            cancelOwnedConnections()
            transition(to: .error)
            scheduleRetry()
        case .cancelled:
            transition(to: .stopped)
        default:
            break
        }
    }

    /// Tears down the listener, cancels all open connections, and transitions
    /// the service to `.stopped`. Safe to call when no server is running.
    func stopServer() {
        listenerGeneration &+= 1
        retryTask?.cancel()
        retryTask = nil

        widgetHTTP?.stop()
        widgetHTTP = nil
        widgetHTTPPort = nil

        stopProgressTimer()

        // Detach the old listener's handlers BEFORE cancelling. Otherwise its
        // asynchronous `.cancelled` event hops into handleListenerState and runs
        // `transition(to: .stopped)` — which, when updateOverlayToken/updateControlToken/updatePort do
        // stopServer(); startServer() back to back, can land after the new
        // listener is already `.listening` and clobber the state to `.stopped`,
        // making handleConnectionState cancel every subsequent overlay client.
        listener?.stateUpdateHandler = nil
        listener?.newConnectionHandler = nil
        listener?.cancel()
        listener = nil

        cancelOwnedConnections()

        transition(to: .stopped)
        Log.info("WebSocketServerService: Server stopped", category: .websocket)
    }

    /// Retries starting the server after a delay if still enabled.
    private func scheduleRetry() {
        guard isEnabled else { return }

        Log.info(
            "WebSocketServerService: Retrying in \(AppConstants.WebSocketServer.retryDelay)s",
            category: .websocket)
        retryTask?.cancel()
        retryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(AppConstants.WebSocketServer.retryDelay))
            guard !Task.isCancelled else { return }
            await self?.attemptRetry()
        }
    }

    /// Retry body: restarts only if still enabled and nothing else already
    /// brought a listener up in the meantime.
    private func attemptRetry() {
        guard isEnabled, listener == nil else { return }
        startServer()
    }
}
