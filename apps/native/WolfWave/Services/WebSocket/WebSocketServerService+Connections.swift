//
//  WebSocketServerService+Connections.swift
//  WolfWave
//
//  Created by Nathanial Henniges on 2026-10-16.
//  Copyright © 2026 MrDemonWolf, Inc. All rights reserved.
//

import Foundation
import Network

/// Connection admission for ``WebSocketServerService``: pending-handshake
/// limits and timeouts, role authentication, promotion and removal, and the
/// inbound receive loop that routes Stream Deck commands.
extension WebSocketServerService {

    // MARK: - Connection Handling

    /// Admits a freshly accepted TCP peer as *pending*: checks the admission
    /// limits (`shouldAcceptNewConnection`), arms the handshake timeout, and
    /// wires the state callback that `handleConnectionState` acts on.
    /// Refused or stale-generation peers are cancelled immediately.
    func handleNewConnection(
        _ connection: NWConnection,
        listenerGeneration generation: UInt64
    ) {
        let isLoopback = WebSocketAuthToken.isLoopbackEndpoint(connection.endpoint)
        let peerKey = WebSocketAuthToken.peerKey(connection.endpoint)
        let peerPendingCount = pendingConnections.lazy.filter {
            WebSocketAuthToken.peerKey($0.endpoint) == peerKey
        }.count
        let remoteActiveCount = connections.lazy.filter {
            !WebSocketAuthToken.isLoopbackEndpoint($0.endpoint)
        }.count
        guard generation == listenerGeneration,
              isEnabled,
              listener != nil,
              Self.shouldAcceptNewConnection(
                  activeCount: connections.count,
                  pendingCount: pendingConnections.count,
                  isLoopback: isLoopback,
                  peerPendingCount: peerPendingCount,
                  remoteActiveCount: remoteActiveCount
              ) else {
            connection.cancel()
            return
        }

        pendingConnections.append(connection)
        let connectionID = ObjectIdentifier(connection)
        handshakeTimeoutTasks[connectionID] = Task { [weak self] in
            do {
                try await Task.sleep(for: Self.handshakeTimeout)
            } catch {
                return
            }
            await self?.expirePendingConnection(
                connection,
                listenerGeneration: generation
            )
        }
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            Task {
                await self.handleConnectionState(
                    connection,
                    state: state,
                    listenerGeneration: generation
                )
            }
        }
        connection.start(queue: networkQueue)
    }

    /// Drives one connection through its lifecycle.
    ///
    /// On `.ready` the gates run in order: still pending (not already promoted
    /// or expired), selected subprotocol re-validated to a role, control role
    /// only from loopback, server still `.listening`. A connection that passes
    /// joins `connections` and gets the connect snapshot: `welcome`,
    /// `widget_config`, `overlay_visibility`, `queue_upcoming`, then the current
    /// playback state. On failure or cancellation it is removed.
    private func handleConnectionState(
        _ connection: NWConnection,
        state: NWConnection.State,
        listenerGeneration generation: UInt64
    ) {
        guard generation == listenerGeneration else {
            connection.cancel()
            return
        }
        switch state {
        case .ready:
            guard !connections.contains(where: { $0 === connection }) else { return }
            guard promotePendingConnection(connection) else {
                removeConnection(connection)
                connection.cancel()
                return
            }
            let metadata = connection.metadata(definition: NWProtocolWebSocket.definition)
                as? NWProtocolWebSocket.Metadata
            guard let role = WebSocketAuthToken.role(
                forSelectedSubprotocol: metadata?.selectedSubprotocol,
                overlayToken: overlayToken,
                controlToken: controlToken
            ) else {
                Log.warn(
                    "WebSocketServerService: Cancelling client with unvalidated selected subprotocol",
                    category: .websocket
                )
                removeConnection(connection)
                connection.cancel()
                return
            }
            let isLoopback = WebSocketAuthToken.isLoopbackEndpoint(connection.endpoint)
            guard Self.allowsConnection(role: role, isLoopback: isLoopback) else {
                Log.warn(
                    "WebSocketServerService: Refusing non-loopback control connection",
                    category: .websocket
                )
                removeConnection(connection)
                connection.cancel()
                return
            }
            // Ignore a late .ready that lands after stopServer(); re-adding would
            // inflate the count. `state` the param is NWConnection.State; qualify
            // with self to read the server's lifecycle state.
            guard self.state == .listening else {
                removeConnection(connection)
                connection.cancel()
                return
            }
            connections.append(connection)
            connectionRoles[ObjectIdentifier(connection)] = role
            let count = connections.count
            writeConnectionCountSnapshot(count)
            Log.info("WebSocketServerService: Client connected (\(count) total)", category: .websocket)
            notifyStateChange()
            sendWelcome(to: connection)
            sendWidgetConfig(to: connection)
            sendOverlayVisibility(to: connection)
            sendQueueUpcoming(to: connection)
            sendCurrentState(to: connection, role: role)
            Self.receiveMessage(
                from: connection,
                role: role,
                isLoopback: isLoopback,
                onCommand: { [weak self] command in
                    await self?.executeCommand(command)
                        ?? CommandAck.failure(command.action.rawValue, "unavailable")
                }
            )
            reconcileProgressTimer()
        case .failed(let error):
            Log.debug("WebSocketServerService: Client failed: \(error)", category: .websocket)
            // Clear actor ownership and the callback before cancelling so an
            // abruptly-dropped peer cannot leave a connection/handler cycle.
            removeConnection(connection)
            connection.cancel()
        case .cancelled:
            removeConnection(connection)
        default:
            break
        }
    }

    /// Drops `connection` from the pending and active sets, cancels its
    /// handshake timeout, and detaches its state handler. Notifies observers
    /// and reconciles the progress timer only when the active count changed.
    /// Does not cancel the connection; callers do that when needed.
    private func removeConnection(_ connection: NWConnection) {
        let previousActiveCount = connections.count
        handshakeTimeoutTasks.removeValue(forKey: ObjectIdentifier(connection))?.cancel()
        pendingConnections.removeAll { $0 === connection }
        connections.removeAll { $0 === connection }
        connectionRoles.removeValue(forKey: ObjectIdentifier(connection))
        connection.stateUpdateHandler = nil
        let count = connections.count
        guard count != previousActiveCount else { return }
        writeConnectionCountSnapshot(count)

        Log.debug("WebSocketServerService: Client disconnected (\(count) remaining)", category: .websocket)
        notifyStateChange()
        reconcileProgressTimer()
    }

    /// Cancels every active and pending connection and clears all per-connection
    /// bookkeeping. Handlers are detached first so the resulting `.cancelled`
    /// events don't re-enter the actor. Does not notify observers; callers
    /// follow with `transition(to:)`.
    func cancelOwnedConnections() {
        let ownedConnections = connections + pendingConnections
        let timeoutTasks = Array(handshakeTimeoutTasks.values)
        connections.removeAll()
        connectionRoles.removeAll()
        pendingConnections.removeAll()
        handshakeTimeoutTasks.removeAll()
        writeConnectionCountSnapshot(0)

        for task in timeoutTasks { task.cancel() }
        for connection in ownedConnections {
            connection.stateUpdateHandler = nil
            connection.cancel()
        }
    }

    /// Moves `connection` out of the pending set and cancels its handshake
    /// timeout.
    /// - Returns: `false` if it was not pending (already expired or removed),
    ///   in which case the caller must drop it.
    private func promotePendingConnection(_ connection: NWConnection) -> Bool {
        guard let index = pendingConnections.firstIndex(where: { $0 === connection }) else {
            return false
        }
        pendingConnections.remove(at: index)
        handshakeTimeoutTasks.removeValue(forKey: ObjectIdentifier(connection))?.cancel()
        return true
    }

    /// Handshake-timeout body: cancels `connection` if it is still pending in
    /// the same listener generation.
    private func expirePendingConnection(
        _ connection: NWConnection,
        listenerGeneration generation: UInt64
    ) {
        guard generation == listenerGeneration,
              pendingConnections.contains(where: { $0 === connection }) else { return }
        removeConnection(connection)
        connection.cancel()
    }

    /// Admission policy for a new TCP peer. Pure, so tests can pin it.
    ///
    /// Every peer is bounded by the global pending cap and by
    /// `maximumConnectionCount` across active plus pending. Non-loopback peers
    /// also face the remote pending cap, the per-host pending cap, and the
    /// remote active cap, which together keep a few slots free for same-Mac
    /// clients. Negative inputs refuse.
    nonisolated static func shouldAcceptNewConnection(
        activeCount: Int,
        pendingCount: Int,
        isLoopback: Bool = true,
        peerPendingCount: Int = 0,
        remoteActiveCount: Int = 0
    ) -> Bool {
        guard activeCount >= 0,
              pendingCount >= 0,
              peerPendingCount >= 0,
              remoteActiveCount >= 0,
              pendingCount < maximumPendingConnectionCount,
              activeCount < maximumConnectionCount - pendingCount else { return false }
        return isLoopback || (
            pendingCount < maximumRemotePendingConnectionCount
                && peerPendingCount < maximumPendingConnectionsPerRemotePeer
                && remoteActiveCount < maximumRemoteConnectionCount - pendingCount
        )
    }

    /// Pure authorization seams shared by the ready-state gate and tests.
    ///
    /// Overlay clients may connect from anywhere; control clients only from a
    /// literal loopback IP.
    nonisolated static func allowsConnection(
        role: WebSocketAuthToken.Role,
        isLoopback: Bool
    ) -> Bool {
        role == .overlay || isLoopback
    }

    /// Whether a connection may run Stream Deck commands: control role from a
    /// loopback peer only. Rechecked per frame even though `allowsConnection`
    /// already refused non-loopback control peers, as defense in depth.
    nonisolated static func allowsCommands(role: WebSocketAuthToken.Role, isLoopback: Bool) -> Bool {
        role == .control && isLoopback
    }

    /// Keeps the connection alive by continuously consuming inbound messages.
    /// Nonisolated. Does not touch actor state.
    ///
    /// Stops re-arming (and cancels the connection) on a WebSocket close frame
    /// or a transport error. A graceful close arrives as a `.close` opcode with
    /// `error == nil`, so keying only on `error` would re-arm `receiveMessage`
    /// forever and keep the dead `NWConnection` retained by the loop.
    ///
    /// Inbound text frames are parsed as Stream Deck control commands
    /// (``StreamDeckControl/parse(_:)``). A valid command runs through
    /// `onCommand` and the ack goes back on the same connection; a rejected
    /// command still acks; anything else is ignored. Overlay credentials never
    /// authorize commands, and control credentials remain loopback-only.
    private static func receiveMessage(
        from connection: NWConnection,
        role: WebSocketAuthToken.Role,
        isLoopback: Bool,
        onCommand: (@Sendable (StreamDeckCommand) async -> CommandAck)?
    ) {
        connection.receiveMessage { data, context, _, error in
            if error != nil { connection.cancel(); return }

            if let metadata = context?.protocolMetadata(definition: NWProtocolWebSocket.definition)
                as? NWProtocolWebSocket.Metadata, metadata.opcode == .close {
                connection.cancel()
                return
            }

            if let data, !data.isEmpty, let text = String(data: data, encoding: .utf8) {
                switch StreamDeckControl.parse(text) {
                case .command(let command):
                    if !allowsCommands(role: role, isLoopback: isLoopback) {
                        sendJSON(
                            CommandAck.failure(command.action.rawValue, "unauthorized").jsonObject,
                            to: connection
                        )
                    } else if let onCommand {
                        Task {
                            let ack = await onCommand(command)
                            sendJSON(ack.jsonObject, to: connection)
                        }
                    } else {
                        sendJSON(CommandAck.failure(command.action.rawValue, "unavailable").jsonObject, to: connection)
                    }
                case .reject(let ack):
                    sendJSON(ack.jsonObject, to: connection)
                case .ignore:
                    break
                }
            }

            receiveMessage(
                from: connection,
                role: role,
                isLoopback: isLoopback,
                onCommand: onCommand
            )
        }
    }
}
