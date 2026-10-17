//
//  DiscordRPCServiceTests+Connection.swift
//  WolfWave
//
//  Created by Nathanial Henniges on 2026-10-16.
//  Copyright © 2026 MrDemonWolf, Inc. All rights reserved.
//

import Darwin
import XCTest

@testable import WolfWave

/// Connect waits, hide-toggle presence, and concurrent command ordering.
extension DiscordRPCServiceTests {
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
}
