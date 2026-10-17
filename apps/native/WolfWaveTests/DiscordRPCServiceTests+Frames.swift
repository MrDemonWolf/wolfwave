//
//  DiscordRPCServiceTests+Frames.swift
//  WolfWave
//
//  Created by Nathanial Henniges on 2026-10-16.
//  Copyright © 2026 MrDemonWolf, Inc. All rights reserved.
//

import Darwin
import XCTest

@testable import WolfWave

/// PING echo, descriptor reuse across disconnects, transaction deadlines, and frame payload decoding.
extension DiscordRPCServiceTests {
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
        let peer = Task.detached { () throws in
            peerReady.signal()
            _ = try readRPCPayload(from: peerFD)
            guard let staleBody = JSONObjectSerialization.data(from: [
                "cmd": "SET_ACTIVITY",
                "nonce": "stale"
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

    // MARK: - Frame payload decode (pure, no live socket)
    //
    // `decodeFramePayload` is the seam behind `readIPCFrame`. A hostile or garbled
    // Discord peer must never crash the IPC read loop, so malformed bytes have
    // to decode to nil, not trap.

    /// Only an opcode-frame `DISPATCH`/`READY` payload counts as handshake completion.
    func testHandshakeAcceptsOnlyFrameDispatchReady() {
        let ready: [String: Any] = [
            "cmd": "DISPATCH",
            "evt": "READY"
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
            "nonce": "expected"
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
}
