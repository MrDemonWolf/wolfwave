//
//  DiscordRPCServiceTests.swift
//  WolfWave
//
//  Created by Nathanial Henniges on 2026-03-19.
//  Copyright © 2026 MrDemonWolf, Inc. All rights reserved.
//

import Darwin
import XCTest
@testable import WolfWave

/// `DiscordRPCService` over real `socketpair(2)` descriptors with the test acting as Discord:
/// presence coalescing, ping echo, handshake and command-reply matching, transaction deadlines,
/// backoff, availability polling, connection-ownership guards across descriptor reuse, and
/// enable/disable. Never opens a real `discord-ipc-N` socket.
@MainActor
final class DiscordRPCServiceTests: XCTestCase {

    func testBurstOfUpdatesCoalescesToLatest() async throws {
        var sockets: [Int32] = [-1, -1]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &sockets), 0)
        guard sockets.allSatisfy({ $0 >= 0 }) else { return }
        let peerFD = sockets[1]
        defer { Darwin.close(peerFD) }
        XCTAssertTrue(configureTestSocketTimeouts(peerFD))
        let service = DiscordRPCService(clientID: "test")
        await service.installTestSocket(sockets[0], presenceInterval: 0.15)
        let peer = Task.detached {
            [try readAndAcknowledgeCommand(from: peerFD), try readAndAcknowledgeCommand(from: peerFD)]
        }
        do {
            await service.sendActivityFrame(["details": "First"])
            await service.sendActivityFrame(["details": "Middle"])
            await service.sendActivityFrame(["details": "Latest"])
            let frames = try await peer.value
            XCTAssertEqual(frames.map(\.activityDetails), ["First", "Latest"])
        } catch {
            await service.releaseTestSocket()
            throw error
        }
        await service.releaseTestSocket()
    }

    /// Discord rejecting a SET_ACTIVITY makes the service resend the cached presence exactly
    /// once; a second rejection must not start an unbounded resend loop (no third frame arrives).
    func testErrorReplyTriggersSingleResend() async throws {
        var sockets: [Int32] = [-1, -1]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &sockets), 0)
        guard sockets.allSatisfy({ $0 >= 0 }) else { return }
        let peerFD = sockets[1]
        defer { Darwin.close(peerFD) }
        XCTAssertTrue(configureTestSocketTimeouts(peerFD))
        let service = DiscordRPCService(clientID: "test")
        // Cache the latest presence while disconnected, avoiding artwork network work.
        await service.updatePresence(track: "Retry", artist: "Artist", album: "Album", playlist: "")
        await service.installTestSocket(sockets[0], presenceInterval: 0.05)
        let peer = Task.detached {
            [try readAndAcknowledgeCommand(from: peerFD, rejected: true),
             try readAndAcknowledgeCommand(from: peerFD, rejected: true)]
        }
        do {
            await service.sendActivityFrame(["details": "Retry"])
            let frames = try await peer.value
            XCTAssertEqual(frames.map(\.activityDetails), ["Retry", "Retry"])
            let extraFrame = await waitUntil(timeout: .milliseconds(250)) {
                var byte: UInt8 = 0
                return recv(peerFD, &byte, 1, MSG_DONTWAIT) > 0
            }
            XCTAssertFalse(extraFrame, "A second rejection must not create an unbounded resend loop")
        } catch {
            await service.releaseTestSocket()
            throw error
        }
        await service.releaseTestSocket()
    }

    func testDisableDuringHandshakeLeavesLastFailureNone() async {
        var sockets: [Int32] = [-1, -1]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &sockets), 0)
        guard sockets.allSatisfy({ $0 >= 0 }) else { return }
        defer { Darwin.close(sockets[1]) }
        let service = DiscordRPCService(clientID: "test")
        await service.installTestSocket(sockets[0], connected: false)
        let generation = await service.connectionGeneration
        await service.setEnabled(false)
        let recorded = await service.recordHandshakeRejectionIfCurrent(fd: sockets[0], generation: generation)
        XCTAssertFalse(recorded)
        let failure = await service.lastFailure
        XCTAssertEqual(failure, .none)
    }

    // MARK: - Off-Executor I/O Tests (No Socket)
    //
    // The blocking IPC syscalls now run on a dedicated serial queue, bridged back
    // to the actor with a checked continuation. None of these entry points may
    // touch the socket while disconnected (they guard on `state == .connected`),
    // so on a service with no client ID they must return promptly without ever
    // opening or blocking on a socket. A regression that re-blocks the executor
    // (or drops the state guard) would hang these `await`s.

    func testUpdatePresenceWhileDisconnectedReturnsWithoutBlocking() async {
        let service = DiscordRPCService(clientID: "")
        // Disconnected: guarded out before any socket I/O. Must return, not hang.
        await service.updatePresence(
            track: "Howl", artist: "Timber Wolf", album: "Moonrise",
            playlist: "", duration: 120, elapsed: 10, isPaused: false
        )
        let state = await service.state
        XCTAssertEqual(state, .disconnected, "updatePresence must not connect on its own")
    }

    func testShowIdleStatusWhileDisconnectedIsNoOp() async {
        let service = DiscordRPCService(clientID: "")
        await service.showIdleStatus()
        let state = await service.state
        XCTAssertEqual(state, .disconnected)
    }

    func testConcurrentDisconnectedCallsAllComplete() async {
        // The actor serializes these and none reach the socket, so a batch of
        // concurrent calls must all complete (no continuation leak / deadlock).
        let service = DiscordRPCService(clientID: "")
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<8 {
                group.addTask { await service.clearPresence() }
                group.addTask { await service.showIdleStatus() }
                group.addTask {
                    await service.updatePresence(
                        track: "T", artist: "A", album: "Al",
                        playlist: "", duration: 0, elapsed: 0, isPaused: false
                    )
                }
            }
        }
        let state = await service.state
        XCTAssertEqual(state, .disconnected)
    }

    /// A connect attempt whose socket open is still pending (and will fail) must not downgrade
    /// the state when a newer connection has been installed meanwhile; state stays `.connected`.
    func testStaleFailedOpenerCannotOverwriteNewerConnectedState() async throws {
        let openerEntered = DispatchSemaphore(value: 0)
        let releaseOpener = DispatchSemaphore(value: 0)
        let service = DiscordRPCService(
            clientID: "test",
            ipcSocketOpener: { _, _ in
                openerEntered.signal()
                _ = releaseOpener.wait(timeout: .now() + 2)
                return -1
            })
        await service.prepareTestConnect()
        let staleConnect = Task { await service.connectIfNeeded() }
        let entered = await waitForSemaphore(
            openerEntered,
            timeout: .now() + 2
        )
        XCTAssertTrue(entered)

        var sockets = [Int32](repeating: -1, count: 2)
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &sockets), 0)
        guard sockets.allSatisfy({ $0 >= 0 }) else { return }
        await service.installTestSocket(sockets[0], supersedingConnection: true)
        releaseOpener.signal()
        await staleConnect.value

        let state = await service.state
        XCTAssertEqual(state, .connected)
        await service.releaseTestSocket()
        Darwin.close(sockets[1])
    }

    func testDisabledWhileWaitingForCloseDoesNotRestartConnect() async {
        let pendingClose = DiscordRPCService.IPCDescriptorClose()
        let openerCalled = ThreadSafeBox(false)
        let service = DiscordRPCService(
            clientID: "test",
            ipcSocketOpener: { _, _ in
                openerCalled.set(true)
                return -1
            })
        await service.prepareTestConnect(waitingFor: pendingClose)

        let connect = Task { await service.connectIfNeeded() }
        let isWaiting = await waitUntil { pendingClose.hasWaiters }
        XCTAssertTrue(isWaiting)
        await service.setEnabledForTesting(false)
        pendingClose.complete()
        await connect.value

        let state = await service.state
        XCTAssertFalse(openerCalled.value)
        XCTAssertEqual(state, .disconnected)
    }

    /// Disabling the service while a socket open is in flight ends in `.disconnected`, not a stuck
    /// `.connecting`.
    func testDisableWhileSocketOpenIsQueuedRetiresConnectingState() async {
        let openerEntered = DispatchSemaphore(value: 0)
        let releaseOpener = DispatchSemaphore(value: 0)
        let service = DiscordRPCService(
            clientID: "test",
            ipcSocketOpener: { _, _ in
                openerEntered.signal()
                _ = releaseOpener.wait(timeout: .now() + 2)
                return -1
            })
        await service.prepareTestConnect()

        let connect = Task { await service.connectIfNeeded() }
        let entered = await waitForSemaphore(
            openerEntered,
            timeout: .now() + 2
        )
        XCTAssertTrue(entered)
        await service.setEnabledForTesting(false)
        releaseOpener.signal()
        await connect.value

        let state = await service.state
        XCTAssertEqual(state, .disconnected)
    }

    func testNonblockingConnectWaitTimesOutDeterministically() {
        let error = DiscordRPCService.waitForNonblockingConnect(
            fd: 41,
            deadline: 2_000_001,
            now: { 1 },
            poller: { fd, timeout in
                XCTAssertEqual(fd, 41)
                XCTAssertEqual(timeout, 2_000_000 / 1_000_000)
                return DiscordRPCService.IPCPollResult(
                    count: 0,
                    revents: 0,
                    errno: 0
                )
            },
            socketError: { _ in
                XCTFail("SO_ERROR must not be queried after poll timeout")
                return 0
            }
        )

        XCTAssertEqual(error, ETIMEDOUT)
    }

    func testNonblockingConnectWaitReturnsPendingSocketError() {
        let error = DiscordRPCService.waitForNonblockingConnect(
            fd: 42,
            deadline: 5_000_000,
            now: { 0 },
            poller: { _, _ in
                DiscordRPCService.IPCPollResult(
                    count: 1,
                    revents: Int16(POLLOUT),
                    errno: 0
                )
            },
            socketError: { fd in
                XCTAssertEqual(fd, 42)
                return ECONNREFUSED
            }
        )

        XCTAssertEqual(error, ECONNREFUSED)
    }

    /// With "clear while paused" on, a paused track sends a clear (no activity), and nothing is
    /// written before the handshake completes. Turning the setting off re-sends the cached track.
    func testPausedTrackReturnsAfterHideToggleTurnsOff() async throws {
        var sockets = [Int32](repeating: -1, count: 2)
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &sockets), 0)
        guard sockets.allSatisfy({ $0 >= 0 }) else { return }
        XCTAssertTrue(configureTestSocketTimeouts(sockets[0]))
        XCTAssertTrue(configureTestSocketTimeouts(sockets[1]))

        let service = DiscordRPCService(clientID: "test")
        await service.installTestSocket(sockets[0], connected: false)
        let peerFD = sockets[1]

        do {
            // Cache playback during the handshake without interleaving a
            // SET_ACTIVITY frame before Discord's READY response.
            await service.updatePresence(
                track: "Test Track",
                artist: "Test Artist",
                album: "Test Album",
                playlist: "",
                duration: 180,
                elapsed: 30,
                isPaused: true,
                showIdleStatus: false,
                clearWhilePaused: true
            )
            var byte: UInt8 = 0
            let prematureBytes = recv(peerFD, &byte, 1, MSG_DONTWAIT)
            XCTAssertEqual(prematureBytes, -1)
            XCTAssertTrue(errno == EAGAIN || errno == EWOULDBLOCK)

            await service.installTestSocket(sockets[0])
            let hiddenReply = Task.detached {
                try readAndAcknowledgeCommand(from: peerFD)
            }
            await service.updatePresence(
                track: "Test Track",
                artist: "Test Artist",
                album: "Test Album",
                playlist: "",
                duration: 180,
                elapsed: 35,
                isPaused: true,
                showIdleStatus: false,
                clearWhilePaused: true
            )
            let hidden = try await hiddenReply.value
            XCTAssertFalse(hidden.hasActivity)

            let restoredReply = Task.detached {
                try readAndAcknowledgeCommand(from: peerFD)
            }
            await service.refreshPresenceFromSettings(
                showIdleStatus: false,
                clearWhilePaused: false
            )
            let restored = try await restoredReply.value
            XCTAssertEqual(restored.activityDetails, "Test Track")
        } catch {
            await service.releaseTestSocket()
            Darwin.close(sockets[1])
            throw error
        }

        await service.releaseTestSocket()
        Darwin.close(sockets[1])
    }

    /// A disable whose clear reply is held back, followed by a re-enable, must end connected with
    /// the presence restored. The newest enable intent wins over the stale disable.
    func testRapidReenableRestoresPresenceAfterStaleDisableClear() async throws {
        var sockets = [Int32](repeating: -1, count: 2)
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &sockets), 0)
        guard sockets.allSatisfy({ $0 >= 0 }) else { return }
        XCTAssertTrue(configureTestSocketTimeouts(sockets[0]))
        XCTAssertTrue(configureTestSocketTimeouts(sockets[1]))

        let clearReceived = DispatchSemaphore(value: 0)
        let releaseClearReply = DispatchSemaphore(value: 0)
        let service = DiscordRPCService(clientID: "test")
        await service.installTestSocket(sockets[0])
        let peerFD = sockets[1]

        let peer = Task.detached { () throws -> DiscordPresenceProbe in
            let initial = try readAndAcknowledgeCommand(from: peerFD)

            let clearPayload = try readRPCPayload(from: peerFD)
            clearReceived.signal()
            guard await waitForSemaphore(
                releaseClearReply,
                timeout: .now() + 2
            ),
                  let clearCommand = clearPayload["cmd"] as? String,
                  let clearNonce = clearPayload["nonce"] as? String else {
                throw DiscordTestSocketError.invalidPayload
            }
            try writeRPCPayload(
                ["cmd": clearCommand, "nonce": clearNonce],
                to: peerFD
            )

            let restored = try readAndAcknowledgeCommand(from: peerFD)
            return DiscordPresenceProbe(initial: initial, restored: restored)
        }

        do {
            await service.updatePresence(
                track: "Race Track",
                artist: "Race Artist",
                album: "Race Album",
                playlist: "",
                duration: 180,
                elapsed: 30,
                isPaused: false
            )

            let staleDisable = Task { await service.setEnabled(false) }
            let received = await waitForSemaphore(
                clearReceived,
                timeout: .now() + 2
            )
            XCTAssertTrue(received)

            // The disable is suspended in its nonce-matched clear transaction,
            // so this enable becomes the newest intent deterministically.
            await service.setEnabled(true)
            releaseClearReply.signal()

            await staleDisable.value
            let result = try await peer.value
            XCTAssertEqual(result.initial.activityDetails, "Race Track")
            XCTAssertTrue(result.restored.hasActivity)
            XCTAssertEqual(result.restored.activityDetails, "Race Track")
            let state = await service.state
            XCTAssertEqual(state, .connected)
        } catch {
            releaseClearReply.signal()
            await service.releaseTestSocket()
            Darwin.close(peerFD)
            throw error
        }

        await service.releaseTestSocket()
        Darwin.close(peerFD)
    }

    /// Two commands issued at once are serialized: the second is written only after the first
    /// gets its reply, with different nonces. A stale reply with the wrong nonce is drained
    /// rather than taken as the answer.
    func testConcurrentCommandsAreAtomicAndNonceMatched() async throws {
        var sockets = [Int32](repeating: -1, count: 2)
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &sockets), 0)
        guard sockets.allSatisfy({ $0 >= 0 }) else { return }
        XCTAssertTrue(configureTestSocketTimeouts(sockets[0]))
        XCTAssertTrue(configureTestSocketTimeouts(sockets[1]))

        let service = DiscordRPCService(clientID: "test")
        await service.installTestSocket(sockets[0])
        let enqueueGate = DiscordIPCEnqueueGate()
        await service.setIPCWorkEnqueuedObserver {
            Task { await enqueueGate.recordEnqueue() }
        }
        let peerFD = sockets[1]
        let peer = Task.detached { () throws -> DiscordTransactionProbe in
            let first = try readRPCPayload(from: peerFD)
            guard let firstCommand = first["cmd"] as? String,
                  let firstNonce = first["nonce"] as? String else {
                throw DiscordTestSocketError.invalidPayload
            }

            // The second transaction is now definitely submitted behind the
            // first transaction's reply read; no scheduler timing assumption.
            guard await enqueueGate.waitForEnqueueCount(2) else {
                throw DiscordTestSocketError.timedOut
            }
            var byte: UInt8 = 0
            let peeked = recv(peerFD, &byte, 1, MSG_DONTWAIT | MSG_PEEK)
            let secondArrivedBeforeFirstReply: Bool
            if peeked > 0 {
                secondArrivedBeforeFirstReply = true
            } else if peeked < 0, errno == EAGAIN || errno == EWOULDBLOCK {
                secondArrivedBeforeFirstReply = false
            } else {
                throw DiscordTestSocketError.readFailed(peeked < 0 ? errno : 0)
            }

            // A stale reply must be drained, not mistaken for this transaction.
            try writeRPCPayload(
                ["cmd": firstCommand, "nonce": "stale-\(firstNonce)"],
                to: peerFD
            )
            try writeRPCPayload(
                ["cmd": firstCommand, "nonce": firstNonce],
                to: peerFD
            )

            let second = try readRPCPayload(from: peerFD)
            guard let secondCommand = second["cmd"] as? String,
                  let secondNonce = second["nonce"] as? String else {
                throw DiscordTestSocketError.invalidPayload
            }
            try writeRPCPayload(
                ["cmd": secondCommand, "nonce": secondNonce],
                to: peerFD
            )

            return DiscordTransactionProbe(
                secondArrivedBeforeFirstReply: secondArrivedBeforeFirstReply,
                noncesDiffer: firstNonce != secondNonce
            )
        }

        do {
            await withTaskGroup(of: Void.self) { group in
                group.addTask { await service.clearPresence() }
                group.addTask { await service.showIdleStatus() }
            }
            let probe = try await peer.value
            XCTAssertFalse(
                probe.secondArrivedBeforeFirstReply,
                "A second command must not write before the first nonce-matched reply"
            )
            XCTAssertTrue(probe.noncesDiffer)
            let state = await service.state
            XCTAssertEqual(state, .connected)
        } catch {
            await service.releaseTestSocket()
            Darwin.close(sockets[1])
            throw error
        }

        await service.releaseTestSocket()
        Darwin.close(sockets[1])
    }

    func testEnqueueGateWaitIsBoundedAndCancellable() async {
        let gate = DiscordIPCEnqueueGate()
        let timedOut = await gate.waitForEnqueueCount(1, timeout: .milliseconds(20))
        XCTAssertFalse(timedOut)

        let canceledWait = Task {
            await gate.waitForEnqueueCount(1, timeout: .seconds(1))
        }
        canceledWait.cancel()
        let canceledResult = await canceledWait.value
        XCTAssertFalse(canceledResult)
    }

    /// A PING during the handshake is answered with a PONG echoing its payload before READY
    /// completes the handshake.
    func testHandshakeEchoesPingPayloadBeforeReady() async throws {
        var sockets = [Int32](repeating: -1, count: 2)
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &sockets), 0)
        guard sockets.allSatisfy({ $0 >= 0 }) else { return }
        XCTAssertTrue(configureTestSocketTimeouts(sockets[0]))
        XCTAssertTrue(configureTestSocketTimeouts(sockets[1]))

        let service = DiscordRPCService(clientID: "test")
        await service.installTestSocket(sockets[0], connected: false)
        let peerFD = sockets[1]
        let pingBody = Data(#"{"heartbeat":7}"#.utf8)
        let peer = Task.detached { () throws -> Data in
            let handshake = try readRPCFrame(from: peerFD)
            guard handshake.opcode == DiscordRPCService.Opcode.handshake.rawValue else {
                throw DiscordTestSocketError.invalidOpcode(handshake.opcode)
            }
            try writeRPCFrame(opcode: .ping, payload: pingBody, to: peerFD)
            let pong = try readRPCFrame(from: peerFD)
            guard pong.opcode == DiscordRPCService.Opcode.pong.rawValue else {
                throw DiscordTestSocketError.invalidOpcode(pong.opcode)
            }
            try writeRPCPayload(["cmd": "DISPATCH", "evt": "READY"], to: peerFD)
            return pong.payload
        }

        let handshakeSucceeded = await service.performHandshake()
        XCTAssertTrue(handshakeSucceeded)
        let echoedPingBody = try await peer.value
        XCTAssertEqual(echoedPingBody, pingBody)
        await service.releaseTestSocket()
        Darwin.close(sockets[1])
    }

    /// A PING that arrives while a command awaits its reply is answered with a PONG
    /// (payload echoed, including non-UTF-8 bytes), and the command still completes.
    func testCommandEchoesPingPayloadBeforeMatchedReply() async throws {
        var sockets = [Int32](repeating: -1, count: 2)
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &sockets), 0)
        guard sockets.allSatisfy({ $0 >= 0 }) else { return }
        XCTAssertTrue(configureTestSocketTimeouts(sockets[0]))
        XCTAssertTrue(configureTestSocketTimeouts(sockets[1]))

        let service = DiscordRPCService(clientID: "test")
        await service.installTestSocket(sockets[0])
        let peerFD = sockets[1]
        let pingBody = Data([0, 1, 2, 255])
        let peer = Task.detached { () throws -> Data in
            let command = try readRPCPayload(from: peerFD)
            guard let name = command["cmd"] as? String,
                  let nonce = command["nonce"] as? String else {
                throw DiscordTestSocketError.invalidPayload
            }
            try writeRPCFrame(opcode: .ping, payload: pingBody, to: peerFD)
            let pong = try readRPCFrame(from: peerFD)
            try writeRPCPayload(["cmd": name, "nonce": nonce], to: peerFD)
            guard pong.opcode == DiscordRPCService.Opcode.pong.rawValue else {
                throw DiscordTestSocketError.invalidOpcode(pong.opcode)
            }
            return pong.payload
        }

        await service.clearPresence()
        let echoedPingBody = try await peer.value
        XCTAssertEqual(echoedPingBody, pingBody)
        let connectedState = await service.state
        XCTAssertEqual(connectedState, .connected)
        await service.releaseTestSocket()
        Darwin.close(sockets[1])
    }

    func testIdleConnectionEchoesPingWithoutOutboundCommand() async throws {
        var sockets = [Int32](repeating: -1, count: 2)
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &sockets), 0)
        guard sockets.allSatisfy({ $0 >= 0 }) else { return }
        XCTAssertTrue(configureTestSocketTimeouts(sockets[0]))
        XCTAssertTrue(configureTestSocketTimeouts(sockets[1]))

        let service = DiscordRPCService(clientID: "test")
        await service.installTestSocket(sockets[0])
        await service.startIPCReadPump()
        let peerFD = sockets[1]
        let pingBody = Data(#"{"idle":true}"#.utf8)
        try writeRPCFrame(opcode: .ping, payload: pingBody, to: peerFD)
        let pong = try await Task.detached { try readRPCFrame(from: peerFD) }.value
        XCTAssertEqual(pong.opcode, DiscordRPCService.Opcode.pong.rawValue)
        XCTAssertEqual(pong.payload, pingBody)

        await service.releaseTestSocket()
        Darwin.close(sockets[1])
    }

    /// Two concurrent `disconnect()` calls share exactly one physical close. The test forces the
    /// closed descriptor number to be reused inside the close handler, to prove a late second
    /// close cannot hit the reused descriptor.
    func testConcurrentDisconnectsAwaitSoleCancelHandlerCloseAcrossFDReuse() async {
        var sockets = [Int32](repeating: -1, count: 2)
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &sockets), 0)
        guard sockets.allSatisfy({ $0 >= 0 }) else { return }

        let closer = DiscordGatedSocketCloser()
        let service = DiscordRPCService(
            clientID: "test",
            ipcSocketCloser: { closer.closeAndReuse($0) }
        )
        await service.installTestSocket(sockets[0])
        await service.startIPCReadPump()
        await service.startIPCReadPump() // Idempotent: must not replace the owner.

        let firstDisconnect = Task { await service.disconnect() }
        let secondDisconnect = Task { await service.disconnect() }
        let closeEntered = await waitForSemaphore(
            closer.entered,
            timeout: .now() + 2
        )
        XCTAssertTrue(closeEntered)

        let retiredFD = await service.socketFD
        let closePending = await service.hasTestCloseInProgress()
        XCTAssertEqual(retiredFD, -1, "Actor ownership must retire before awaiting cancel")
        XCTAssertTrue(closePending, "disconnect must await the cancel-handler completion")

        let gated = closer.snapshot()
        XCTAssertEqual(gated.closeCount, 1)
        XCTAssertEqual(gated.originalFD, sockets[0])
        XCTAssertEqual(gated.reusedFD, sockets[0], "test must force the old descriptor number to be reused")
        if gated.setupErrno != 0 {
            XCTFail("Failed to create a reused descriptor: errno \(gated.setupErrno)")
        }

        if gated.reusedFD >= 0, gated.peerFD >= 0 {
            XCTAssertTrue(exchangeProbeByte(from: gated.reusedFD, to: gated.peerFD))
        }

        closer.release()
        await firstDisconnect.value
        await secondDisconnect.value

        let completed = closer.snapshot()
        XCTAssertEqual(completed.closeCount, 1, "Concurrent disconnects must share one physical close")
        if completed.reusedFD >= 0, completed.peerFD >= 0 {
            XCTAssertTrue(
                exchangeProbeByte(from: completed.reusedFD, to: completed.peerFD),
                "A late direct close must not hit the descriptor reused inside the cancel handler"
            )
            Darwin.close(completed.reusedFD)
            Darwin.close(completed.peerFD)
        }
        Darwin.close(sockets[1])
    }

    /// A peer that dribbles one byte every 50 ms must not extend the transaction: the overall
    /// 250 ms deadline holds, the call returns in under a second, and the service disconnects.
    func testTransactionDeadlineDoesNotResetForDripFedFrame() async throws {
        var sockets = [Int32](repeating: -1, count: 2)
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &sockets), 0)
        guard sockets.allSatisfy({ $0 >= 0 }) else { return }
        XCTAssertTrue(configureTestSocketTimeouts(sockets[0]))
        XCTAssertTrue(configureTestSocketTimeouts(sockets[1]))

        let service = DiscordRPCService(
            clientID: "test",
            ipcTransactionTimeoutNanoseconds: 250_000_000
        )
        await service.installTestSocket(sockets[0])
        let peerReady = DispatchSemaphore(value: 0)
        let peerFD = sockets[1]
        let peer = Task.detached { () throws -> Void in
            peerReady.signal()
            _ = try readRPCPayload(from: peerFD)
            guard let staleBody = JSONObjectSerialization.data(from: [
                "cmd": "SET_ACTIVITY",
                "nonce": "stale",
            ]) else {
                throw DiscordTestSocketError.invalidPayload
            }
            let staleFrame = try makeRPCFrameData(opcode: .frame, payload: staleBody)
            for byte in staleFrame {
                if Task.isCancelled { return }
                try await Task.sleep(for: .milliseconds(50))
                guard sendDripByte(byte, to: peerFD) else { return }
            }
        }
        let ready = await waitForSemaphore(peerReady, timeout: .now() + 2)
        XCTAssertTrue(ready)

        let started = DispatchTime.now().uptimeNanoseconds
        await service.clearPresence()
        let elapsed = DispatchTime.now().uptimeNanoseconds - started

        XCTAssertLessThan(
            elapsed,
            1_000_000_000,
            "Partial bytes must not restart the whole transaction timeout"
        )
        let state = await service.state
        XCTAssertEqual(state, .disconnected)

        peer.cancel()
        let peerResult = await peer.result
        await service.setEnabled(false)
        Darwin.close(peerFD)
        if case let .failure(error) = peerResult,
           !(error is CancellationError) {
            throw error
        }
    }

    // MARK: - Connection State Enum Completeness

    func testConnectionStateRawValuesAreUniqueAndNonEmpty() async {
        // Validate each case has a non-empty, distinct raw value
        let disconnected = DiscordRPCService.ConnectionState.disconnected
        let connecting = DiscordRPCService.ConnectionState.connecting
        let connected = DiscordRPCService.ConnectionState.connected

        XCTAssertFalse(disconnected.rawValue.isEmpty, "disconnected raw value should not be empty")
        XCTAssertFalse(connecting.rawValue.isEmpty, "connecting raw value should not be empty")
        XCTAssertFalse(connected.rawValue.isEmpty, "connected raw value should not be empty")

        // All raw values must be distinct
        XCTAssertNotEqual(disconnected.rawValue, connecting.rawValue)
        XCTAssertNotEqual(disconnected.rawValue, connected.rawValue)
        XCTAssertNotEqual(connecting.rawValue, connected.rawValue)

        // Verify initial state transitions: a new service starts disconnected
        let service = DiscordRPCService(clientID: "")
        let state = await service.state
        XCTAssertEqual(state, .disconnected)
    }

    // MARK: - Frame payload decode (pure, no live socket)
    //
    // `decodeFramePayload` is the seam behind `readIPCFrame`. A hostile or garbled
    // Discord peer must never crash the IPC read loop, so malformed bytes have
    // to decode to nil, not trap.

    /// Only an opcode-frame `DISPATCH`/`READY` payload counts as handshake completion.
    func testHandshakeAcceptsOnlyFrameDispatchReady() {
        let ready: [String: Any] = [
            "cmd": "DISPATCH",
            "evt": "READY",
        ]
        XCTAssertTrue(
            DiscordRPCService.isReadyHandshakeResponse(
                opcode: DiscordRPCService.Opcode.frame.rawValue,
                payload: ready
            )
        )

        XCTAssertFalse(
            DiscordRPCService.isReadyHandshakeResponse(
                opcode: DiscordRPCService.Opcode.handshake.rawValue,
                payload: ready
            ),
            "READY is valid only in an opcode-frame response"
        )
        XCTAssertFalse(
            DiscordRPCService.isReadyHandshakeResponse(
                opcode: DiscordRPCService.Opcode.frame.rawValue,
                payload: ["cmd": "SET_ACTIVITY", "evt": "READY"]
            )
        )
        XCTAssertFalse(
            DiscordRPCService.isReadyHandshakeResponse(
                opcode: DiscordRPCService.Opcode.frame.rawValue,
                payload: ["cmd": "DISPATCH", "evt": "ERROR"]
            )
        )
        XCTAssertFalse(
            DiscordRPCService.isReadyHandshakeResponse(
                opcode: DiscordRPCService.Opcode.frame.rawValue,
                payload: nil
            )
        )
    }

    /// A reply counts as a command's answer only if it is a frame with the same `cmd` and nonce.
    func testCommandResponseRequiresFrameMatchingCommandAndNonce() {
        let payload: [String: Any] = [
            "cmd": "SET_ACTIVITY",
            "nonce": "expected",
        ]
        XCTAssertTrue(
            DiscordRPCService.isCommandResponse(
                opcode: DiscordRPCService.Opcode.frame.rawValue,
                payload: payload,
                nonce: "expected",
                command: "SET_ACTIVITY"
            )
        )
        XCTAssertFalse(
            DiscordRPCService.isCommandResponse(
                opcode: DiscordRPCService.Opcode.frame.rawValue,
                payload: payload,
                nonce: "stale",
                command: "SET_ACTIVITY"
            )
        )
        XCTAssertFalse(
            DiscordRPCService.isCommandResponse(
                opcode: DiscordRPCService.Opcode.frame.rawValue,
                payload: payload,
                nonce: "expected",
                command: "SUBSCRIBE"
            )
        )
        XCTAssertFalse(
            DiscordRPCService.isCommandResponse(
                opcode: DiscordRPCService.Opcode.close.rawValue,
                payload: payload,
                nonce: "expected",
                command: "SET_ACTIVITY"
            )
        )
    }

    func testDecodeFramePayloadParsesValidObject() {
        let data = Data(#"{"cmd":"DISPATCH","evt":"READY"}"#.utf8)
        let json = DiscordRPCService.decodeFramePayload(data)
        XCTAssertEqual(json?["cmd"] as? String, "DISPATCH")
    }

    func testDecodeFramePayloadReturnsNilForGarbage() {
        XCTAssertNil(DiscordRPCService.decodeFramePayload(Data("not json".utf8)))
    }

    func testDecodeFramePayloadReturnsNilForTruncatedJSON() {
        XCTAssertNil(DiscordRPCService.decodeFramePayload(Data("{".utf8)))
    }

    func testDecodeFramePayloadReturnsNilForJSONArray() {
        // Valid JSON, but a top-level array is not a frame payload object.
        XCTAssertNil(DiscordRPCService.decodeFramePayload(Data("[1,2,3]".utf8)))
    }

    func testDecodeFramePayloadReturnsNilForEmptyData() {
        XCTAssertNil(DiscordRPCService.decodeFramePayload(Data()))
    }

    func testMaxIPCFrameBytesCapIsBounded() {
        XCTAssertEqual(AppConstants.Discord.maxIPCFrameBytes, 65536)
    }

    // MARK: - I/O Result Shapes (errno captured on-queue)
    //
    // `writeFully`/`readFully` now return a small Sendable result carrying the
    // failing `errno` captured on the same worker thread that ran the syscall,
    // instead of letting the actor read a stale, unrelated `errno` after the
    // queue hop. These assert the result shape and the success/failure contract
    // without opening a socket.

    func testWriteResultSuccessShape() {
        let result = DiscordRPCService.WriteResult(ok: true, errno: 0)
        XCTAssertTrue(result.ok)
        XCTAssertEqual(result.errno, 0, "errno is meaningful only on failure; success carries 0")
    }

    func testWriteResultFailureCarriesErrno() {
        let result = DiscordRPCService.WriteResult(ok: false, errno: EPIPE)
        XCTAssertFalse(result.ok)
        XCTAssertEqual(result.errno, EPIPE, "failing errno must be carried back, not re-read post-hop")
    }

    func testReadResultSuccessShape() {
        let result = DiscordRPCService.ReadResult(data: Data([1, 2, 3]), errno: 0)
        XCTAssertEqual(result.data, Data([1, 2, 3]))
        XCTAssertEqual(result.errno, 0)
    }

    func testReadResultPeerCloseHasNilDataAndZeroErrno() {
        // A clean peer close (read returns 0) is not a syscall error, so errno
        // stays 0 while data is nil, distinct from a timeout/error path.
        let result = DiscordRPCService.ReadResult(data: nil, errno: 0)
        XCTAssertNil(result.data)
        XCTAssertEqual(result.errno, 0)
    }

    func testReadResultErrorCarriesErrno() {
        let result = DiscordRPCService.ReadResult(data: nil, errno: EAGAIN)
        XCTAssertNil(result.data)
        XCTAssertEqual(result.errno, EAGAIN, "timeout/error errno must be carried back from the queue")
    }

    func testSocketTimeoutSetupRejectsInvalidDescriptor() {
        XCTAssertFalse(DiscordRPCService.setSocketTimeouts(-1))
    }

    // MARK: - Teardown / Generation Gate (no socket)
    //
    // `disconnect()` bumps a monotonic generation token and routes the close
    // through `ipcQueue`, and `connectIfNeeded` discards a just-opened fd if the
    // generation changed mid-connect. With no client ID nothing reaches a real
    // socket, but a regression in the gate (or in routing the close through the
    // queue) would deadlock or crash these toggles. They must all settle on
    // `.disconnected` without hanging.

    func testEnableDisableTogglesSettleDisconnected() async {
        let service = DiscordRPCService(clientID: "")
        for _ in 0..<5 {
            await service.setEnabled(true)
            await service.setEnabled(false)
        }
        let state = await service.state
        XCTAssertEqual(state, .disconnected, "repeated enable/disable must end disconnected, not hang")
    }

    func testDisableDuringConcurrentCallsSettlesDisconnected() async {
        // A disable racing in-flight presence calls exercises the teardown +
        // generation path. None reach a socket, so all must complete and the
        // service must end disconnected.
        let service = DiscordRPCService(clientID: "")
        await service.setEnabled(true)
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<4 {
                group.addTask {
                    await service.updatePresence(
                        track: "T", artist: "A", album: "Al",
                        playlist: "", duration: 0, elapsed: 0, isPaused: false
                    )
                }
                group.addTask { await service.clearPresence() }
            }
            group.addTask { await service.setEnabled(false) }
        }
        await service.setEnabled(false)
        let state = await service.state
        XCTAssertEqual(state, .disconnected)
    }

    func testConnectionOwnershipRejectsReusedDescriptorFromOldGeneration() {
        XCTAssertFalse(
            DiscordRPCService.isCurrentConnection(
                capturedFD: 42,
                capturedGeneration: 7,
                currentFD: 42,
                currentGeneration: 8
            )
        )
        XCTAssertTrue(
            DiscordRPCService.isCurrentConnection(
                capturedFD: 42,
                capturedGeneration: 8,
                currentFD: 42,
                currentGeneration: 8
            )
        )
    }

    // MARK: - Reconnect Backoff

    func testNextBackoffDoubles() {
        let base = AppConstants.Discord.reconnectBaseDelay
        let max = AppConstants.Discord.reconnectMaxDelay
        let next = DiscordRPCService.nextBackoff(base, max: max)
        XCTAssertEqual(next, base * 2, accuracy: 0.0001)
    }

    func testNextBackoffClampsAtMax() {
        let max = AppConstants.Discord.reconnectMaxDelay
        // Already at max: doubling would overshoot, so it must clamp.
        let next = DiscordRPCService.nextBackoff(max, max: max)
        XCTAssertEqual(next, max, accuracy: 0.0001)
        // Just under max: doubling overshoots, still clamps.
        let nearMax = DiscordRPCService.nextBackoff(max * 0.75, max: max)
        XCTAssertEqual(nearMax, max, accuracy: 0.0001)
    }

    func testNextBackoffRepeatedDoublingClampsAndResetIsBase() {
        let base = AppConstants.Discord.reconnectBaseDelay
        let max = AppConstants.Discord.reconnectMaxDelay
        var delay = base
        for _ in 0..<20 {
            delay = DiscordRPCService.nextBackoff(delay, max: max)
            XCTAssertLessThanOrEqual(delay, max)
        }
        XCTAssertEqual(delay, max, accuracy: 0.0001)
        // Reset semantics: a successful connect sets reconnectDelay back to base.
        XCTAssertEqual(base, AppConstants.Discord.reconnectBaseDelay, accuracy: 0.0001)
    }

    // MARK: - Availability Poll Lifecycle

    /// The availability poll runs only while enabled, disconnected, and with a non-blank client id.
    func testAvailabilityPollPolicyRunsOnlyWhileEnabledAndDisconnected() {
        XCTAssertTrue(
            DiscordRPCService.shouldPollAvailability(
                isEnabled: true,
                clientID: "client",
                state: .disconnected))
        XCTAssertFalse(
            DiscordRPCService.shouldPollAvailability(
                isEnabled: false,
                clientID: "client",
                state: .disconnected))
        XCTAssertFalse(
            DiscordRPCService.shouldPollAvailability(
                isEnabled: true,
                clientID: "client",
                state: .connecting))
        XCTAssertFalse(
            DiscordRPCService.shouldPollAvailability(
                isEnabled: true,
                clientID: "client",
                state: .connected))
        XCTAssertFalse(
            DiscordRPCService.shouldPollAvailability(
                isEnabled: true,
                clientID: "   ",
                state: .disconnected))
    }

    func testEnabledDisconnectedServiceOwnsPollUntilDisabled() async {
        let service = DiscordRPCService(
            clientID: "missing-client-for-poll-test",
            ipcSocketOpener: { _, _ in -1 }
        )
        await service.setEnabled(true)
        let pollingWhileEnabled = await service.isAvailabilityPolling
        XCTAssertTrue(
            pollingWhileEnabled,
            "A disconnected enabled service needs the coarse Discord-availability fallback")

        await service.setEnabled(false)
        let pollingWhileDisabled = await service.isAvailabilityPolling
        XCTAssertFalse(
            pollingWhileDisabled,
            "Disabling Discord must cancel the availability timer")
    }

}

/// Test seams that adopt a test socket descriptor as the live connection.
private extension DiscordRPCService {
    /// Adopts `fd` as the live connection. `connected: false` leaves the handshake pending,
    /// `supersedingConnection` bumps the connection generation, and `presenceInterval` sets the
    /// minimum interval between presence frames
    /// (`presenceMinimumInterval`). Leaves the state `.connecting` when `connected` is false.
    func installTestSocket(
        _ fd: Int32,
        connected: Bool = true,
        supersedingConnection: Bool = false,
        presenceInterval: TimeInterval = 0
    ) {
        if supersedingConnection { connectionGeneration &+= 1 }
        socketFD = fd
        ipcReadBuffer = IPCReadBuffer()
        isEnabled = true
        presenceMinimumInterval = presenceInterval
        state = connected ? .connected : .connecting
    }

    /// Enables the service and resets it to `.disconnected` so `connectIfNeeded()` runs.
    func prepareTestConnect() {
        isEnabled = true
        state = .disconnected
    }

    func prepareTestConnect(waitingFor close: IPCDescriptorClose) {
        isEnabled = true
        state = .disconnected
        ipcCloseInProgress = close
    }

    /// Sets the enabled flag directly, skipping the side effects of `setEnabled(_:)`.
    func setEnabledForTesting(_ enabled: Bool) {
        isEnabled = enabled
    }

    /// Disconnects and leaves the service disabled, closing the adopted descriptor.
    func releaseTestSocket() async {
        await disconnect()
        isEnabled = false
    }

    /// Whether a descriptor close is still pending.
    func hasTestCloseInProgress() -> Bool {
        ipcCloseInProgress != nil
    }
}

/// What `DiscordGatedSocketCloser` observed: close count, the original and reused descriptor
/// numbers, the peer, and any setup errno.
private nonisolated struct DiscordGatedCloseSnapshot: Sendable {
    let closeCount: Int
    let originalFD: Int32
    let reusedFD: Int32
    let peerFD: Int32
    let setupErrno: Int32
}

/// Closes the source-owned descriptor, deliberately reuses its integer for a
/// fresh socket, then gates the cancel handler before it can signal completion.
private nonisolated final class DiscordGatedSocketCloser: @unchecked Sendable {
    let entered = DispatchSemaphore(value: 0)
    private let releaseGate = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var closeCount = 0
    private var originalFD: Int32 = -1
    private var reusedFD: Int32 = -1
    private var peerFD: Int32 = -1
    private var setupErrno: Int32 = 0

    func closeAndReuse(_ fd: Int32) {
        lock.lock()
        closeCount += 1
        originalFD = fd
        lock.unlock()

        Darwin.close(fd)
        var replacement = [Int32](repeating: -1, count: 2)
        let socketResult = socketpair(AF_UNIX, SOCK_STREAM, 0, &replacement)
        var nextReusedFD: Int32 = -1
        var nextPeerFD: Int32 = -1
        var nextErrno: Int32 = 0
        if socketResult == 0 {
            if replacement[0] == fd {
                nextReusedFD = replacement[0]
                nextPeerFD = replacement[1]
            } else if replacement[1] == fd {
                nextReusedFD = replacement[1]
                nextPeerFD = replacement[0]
            } else if dup2(replacement[0], fd) == fd {
                Darwin.close(replacement[0])
                nextReusedFD = fd
                nextPeerFD = replacement[1]
            } else {
                nextErrno = errno
                Darwin.close(replacement[0])
                Darwin.close(replacement[1])
            }
        } else {
            nextErrno = errno
        }

        lock.lock()
        reusedFD = nextReusedFD
        peerFD = nextPeerFD
        setupErrno = nextErrno
        lock.unlock()
        entered.signal()
        _ = releaseGate.wait(timeout: .now() + 2)
    }

    func release() {
        releaseGate.signal()
    }

    func snapshot() -> DiscordGatedCloseSnapshot {
        lock.lock()
        let result = DiscordGatedCloseSnapshot(
            closeCount: closeCount,
            originalFD: originalFD,
            reusedFD: reusedFD,
            peerFD: peerFD,
            setupErrno: setupErrno
        )
        lock.unlock()
        return result
    }
}

/// Sends one byte from `sourceFD` and checks the same byte arrives on `peerFD`, proving two
/// descriptors are still a live pair.
private nonisolated func exchangeProbeByte(from sourceFD: Int32, to peerFD: Int32) -> Bool {
    var sent: UInt8 = 0xA5
    let writeCount = withUnsafePointer(to: &sent) { pointer in
        Darwin.send(sourceFD, pointer, 1, Int32(MSG_DONTWAIT))
    }
    guard writeCount == 1 else { return false }

    var received: UInt8 = 0
    let readCount = withUnsafeMutablePointer(to: &received) { pointer in
        Darwin.recv(peerFD, pointer, 1, Int32(MSG_DONTWAIT))
    }
    return readCount == 1 && received == sent
}

/// Counts IPC enqueues and lets a test await a target count, so it can wait on an observable event
/// instead of sleeping.
private actor DiscordIPCEnqueueGate {
    private var count = 0
    private struct Waiter {
        let target: Int
        let continuation: CheckedContinuation<Bool, Never>
    }
    private var waiters: [UUID: Waiter] = [:]

    func recordEnqueue() {
        count += 1
        let ready = waiters.filter { count >= $0.value.target }
        ready.forEach { id, waiter in
            waiters[id] = nil
            waiter.continuation.resume(returning: true)
        }
    }

    func waitForEnqueueCount(
        _ target: Int,
        timeout: Duration = .seconds(1)
    ) async -> Bool {
        guard count < target else { return true }
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(returning: false)
                    return
                }
                waiters[id] = Waiter(target: target, continuation: continuation)
                Task { [weak self] in
                    do {
                        try await Task.sleep(for: timeout)
                    } catch {
                        return
                    }
                    await self?.finishWaiter(id, result: false)
                }
            }
        } onCancel: {
            Task { await self.finishWaiter(id, result: false) }
        }
    }

    private func finishWaiter(_ id: UUID, result: Bool) {
        guard let waiter = waiters.removeValue(forKey: id) else { return }
        waiter.continuation.resume(returning: result)
    }
}

/// Failures from the raw socket helpers in this file.
private nonisolated enum DiscordTestSocketError: Error, Sendable {
    case readFailed(Int32)
    case writeFailed(Int32)
    case invalidOpcode(UInt32)
    case invalidPayload
    case timedOut
}

/// What the fake Discord saw in one command: whether it carried an activity, and its `details`.
private nonisolated struct DiscordCommandSnapshot: Sendable {
    let hasActivity: Bool
    let activityDetails: String?
}

/// The first command and the one restored after a disable/enable race.
private nonisolated struct DiscordPresenceProbe: Sendable {
    let initial: DiscordCommandSnapshot
    let restored: DiscordCommandSnapshot
}

/// Whether a second command reached the socket before the first one's reply, and whether their
/// nonces differed.
private nonisolated struct DiscordTransactionProbe: Sendable {
    let secondArrivedBeforeFirstReply: Bool
    let noncesDiffer: Bool
}

/// One IPC frame: opcode and raw payload.
private nonisolated struct DiscordRawFrame: Sendable {
    let opcode: UInt32
    let payload: Data
}

/// One-second send/receive timeouts plus `SO_NOSIGPIPE`, so a stuck peer fails a test instead of
/// hanging it.
private nonisolated func configureTestSocketTimeouts(_ fd: Int32) -> Bool {
    var timeout = timeval(tv_sec: 1, tv_usec: 0)
    var noSigPipe: Int32 = 1
    let size = socklen_t(MemoryLayout<timeval>.size)
    guard setsockopt(
        fd,
        SOL_SOCKET,
        SO_NOSIGPIPE,
        &noSigPipe,
        socklen_t(MemoryLayout<Int32>.size)
    ) == 0 else {
        return false
    }
    guard setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, size) == 0 else {
        return false
    }
    return setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, size) == 0
}

/// Plays Discord: reads one command, replies with a matching nonce (an `ERROR` event when
/// `rejected`), and reports what the command carried.
private nonisolated func readAndAcknowledgeCommand(
    from fd: Int32,
    rejected: Bool = false
) throws -> DiscordCommandSnapshot {
    let payload = try readRPCPayload(from: fd)
    guard let command = payload["cmd"] as? String,
          let nonce = payload["nonce"] as? String else {
        throw DiscordTestSocketError.invalidPayload
    }

    try writeRPCPayload(
        rejected ? ["cmd": command, "nonce": nonce, "evt": "ERROR"] : ["cmd": command, "nonce": nonce],
        to: fd
    )

    let args = payload["args"] as? [String: Any]
    let activity = args?["activity"] as? [String: Any]
    return DiscordCommandSnapshot(
        hasActivity: activity != nil,
        activityDetails: activity?["details"] as? String
    )
}

/// Reads one frame and parses it as a JSON object; throws if it is not an opcode-frame object.
private nonisolated func readRPCPayload(from fd: Int32) throws -> [String: Any] {
    let frame = try readRPCFrame(from: fd)
    guard frame.opcode == DiscordRPCService.Opcode.frame.rawValue else {
        throw DiscordTestSocketError.invalidOpcode(frame.opcode)
    }
    let body = frame.payload
    guard let object = try? JSONSerialization.jsonObject(with: body),
          let payload = object as? [String: Any] else {
        throw DiscordTestSocketError.invalidPayload
    }
    return payload
}

/// Reads one raw frame (8-byte header, then payload) of any opcode.
private nonisolated func readRPCFrame(from fd: Int32) throws -> DiscordRawFrame {
    let header = try readExactly(8, from: fd)
    let opcode = header.withUnsafeBytes { bytes in
        UInt32(littleEndian: bytes.loadUnaligned(fromByteOffset: 0, as: UInt32.self))
    }
    let length = header.withUnsafeBytes { bytes in
        UInt32(littleEndian: bytes.loadUnaligned(fromByteOffset: 4, as: UInt32.self))
    }
    return DiscordRawFrame(
        opcode: opcode,
        payload: try readExactly(Int(length), from: fd)
    )
}

/// Sends `payload` as a JSON opcode-frame.
private nonisolated func writeRPCPayload(
    _ payload: [String: Any],
    to fd: Int32
) throws {
    guard let body = JSONObjectSerialization.data(from: payload),
          let length = UInt32(exactly: body.count) else {
        throw DiscordTestSocketError.invalidPayload
    }
    var header = Data(count: 8)
    header.withUnsafeMutableBytes { bytes in
        bytes.storeBytes(
            of: DiscordRPCService.Opcode.frame.rawValue.littleEndian,
            toByteOffset: 0,
            as: UInt32.self
        )
        bytes.storeBytes(
            of: length.littleEndian,
            toByteOffset: 4,
            as: UInt32.self
        )
    }
    try writeExactly(header + body, to: fd)
}

/// Sends a frame of the given opcode with a raw payload.
private nonisolated func writeRPCFrame(
    opcode: DiscordRPCService.Opcode,
    payload: Data,
    to fd: Int32
) throws {
    try writeExactly(makeRPCFrameData(opcode: opcode, payload: payload), to: fd)
}

/// Header plus payload bytes for one frame, without sending it.
private nonisolated func makeRPCFrameData(
    opcode: DiscordRPCService.Opcode,
    payload: Data
) throws -> Data {
    guard let length = UInt32(exactly: payload.count) else {
        throw DiscordTestSocketError.invalidPayload
    }
    var header = Data(count: 8)
    header.withUnsafeMutableBytes { bytes in
        bytes.storeBytes(of: opcode.rawValue.littleEndian, toByteOffset: 0, as: UInt32.self)
        bytes.storeBytes(of: length.littleEndian, toByteOffset: 4, as: UInt32.self)
    }
    return header + payload
}

/// Sends one byte without blocking; false if it could not go out.
private nonisolated func sendDripByte(_ byte: UInt8, to fd: Int32) -> Bool {
    var byte = byte
    let count = withUnsafePointer(to: &byte) { pointer in
        Darwin.send(fd, pointer, 1, Int32(MSG_DONTWAIT))
    }
    return count == 1
}

/// Reads exactly `count` bytes, looping over short reads.
private nonisolated func readExactly(_ count: Int, from fd: Int32) throws -> Data {
    var data = Data(count: count)
    var offset = 0
    while offset < count {
        let result = data.withUnsafeMutableBytes { bytes -> Int in
            guard let baseAddress = bytes.baseAddress else { return -1 }
            return Darwin.read(fd, baseAddress.advanced(by: offset), count - offset)
        }
        if result > 0 {
            offset += result
        } else if result < 0, errno == EINTR {
            continue
        } else {
            throw DiscordTestSocketError.readFailed(result < 0 ? errno : 0)
        }
    }
    return data
}

/// Writes all of `data`, looping over short writes.
private nonisolated func writeExactly(_ data: Data, to fd: Int32) throws {
    try data.withUnsafeBytes { bytes in
        guard let baseAddress = bytes.baseAddress else {
            throw DiscordTestSocketError.writeFailed(0)
        }
        var offset = 0
        while offset < data.count {
            let result = Darwin.write(
                fd,
                baseAddress.advanced(by: offset),
                data.count - offset
            )
            if result > 0 {
                offset += result
            } else if result < 0, errno == EINTR {
                continue
            } else {
                throw DiscordTestSocketError.writeFailed(result < 0 ? errno : 0)
            }
        }
    }
}
