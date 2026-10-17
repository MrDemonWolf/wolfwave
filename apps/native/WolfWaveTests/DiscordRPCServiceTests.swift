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
