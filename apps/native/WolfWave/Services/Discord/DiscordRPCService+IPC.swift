//
//  DiscordRPCService+IPC.swift
//  WolfWave
//
//  Created by Nathanial Henniges on 2026-07-15.
//  Copyright © 2026 MrDemonWolf, Inc. All rights reserved.
//

import Darwin
import Foundation

/// Socket lifecycle, Discord IPC framing, the idle inbound pump, and
/// reconnection for ``DiscordRPCService``.
///
/// Every blocking syscall runs on ``DiscordRPCService/ipcQueue`` through
/// `runOnIPCQueue`; actor-side code only captures `(fd, generation)` before an
/// await and re-checks ownership after it, because the actor is reentrant and
/// fd integers are recycled by the OS.
extension DiscordRPCService {

    // MARK: - Connection

    /// Attempts to connect to Discord's IPC socket.
    ///
    /// Tries each candidate temp directory, and within each, tries sockets 0 through 9.
    /// Keeps the first successful connection.
    ///
    /// No-op unless enabled and ``ConnectionState/disconnected``. Waits for any
    /// in-flight close first. On success sets ``ConnectionState/connected``,
    /// resets the backoff, re-sends the current presence, and starts the read
    /// pump. On failure records ``lastFailure`` (`notConfigured`,
    /// `socketUnavailable`, `handshakeRejected`, or `notRunning`) and returns to
    /// ``ConnectionState/disconnected``. Any concurrent disable or teardown
    /// (generation change) makes the attempt close its fd and bail.
    func connectIfNeeded() async {
        if let pendingClose = ipcCloseInProgress {
            await pendingClose.wait()
            if ipcCloseInProgress === pendingClose {
                ipcCloseInProgress = nil
            }
        }
        // The close wait is an actor-reentrancy point. A disable may have won
        // while it was suspended, so do not let the stale connect publish a
        // new `.connecting` state after the final user intent is already off.
        guard isEnabled else { return }
        guard state == .disconnected else { return }
        lastFailure = .none
        guard !clientID.isEmpty else {
            Log.warn("DiscordRPCService: No client ID configured: skipping connection", category: .discord)
            lastFailure = .notConfigured
            return
        }

        state = .connecting
        let attemptGeneration = connectionGeneration

        let candidates = tempDirectoryCandidates()
        guard !candidates.isEmpty else {
            Log.error("DiscordRPCService: Cannot determine any temp directory", category: .discord)
            lastFailure = .socketUnavailable
            state = .disconnected
            return
        }

        for basePath in candidates {
            Log.debug("DiscordRPCService: Searching for IPC socket in \(basePath)", category: .discord)

            for slot in 0..<AppConstants.Discord.ipcSocketSlots {
                let socketPath = URL(filePath: basePath)
                    .appending(path: "\(AppConstants.Discord.ipcSocketPrefix)\(slot)")
                    .path(percentEncoded: false)

                // The blocking `connect()` (plus the socket setup and timeout
                // opts it gates) runs off the actor executor on `ipcQueue`. On
                // success it returns the ready fd with timeouts applied; on
                // failure it returns -1 after closing any partial fd. The actor
                // only records the result and runs the handshake.
                //
                // Capture the generation BEFORE the await. If a disconnect /
                // teardown bumps it (or the service is disabled) while the open
                // is in flight, close the just-opened fd on `ipcQueue` and bail
                // without committing `socketFD`/`state`, so a stale connect can
                // never overwrite a fresh teardown.
                let opener = ipcSocketOpener
                let fd = await runOnIPCQueue { opener(socketPath, slot) }
                guard isEnabled,
                      connectionGeneration == attemptGeneration,
                      state == .connecting else {
                    if fd >= 0 {
                        let closer = ipcSocketCloser
                        await runOnIPCQueue { closer(fd) }
                    }
                    // If this attempt still owns the generation, a disable
                    // interleaved after the opener was queued but before it
                    // returned. Retire its transient state so a later enable
                    // can start a fresh connection. Never overwrite a newer
                    // generation's state.
                    if connectionGeneration == attemptGeneration,
                       state == .connecting {
                        state = .disconnected
                    }
                    return
                }
                guard fd >= 0 else { continue }

                socketFD = fd
                ipcReadBuffer = IPCReadBuffer()
                if await performHandshake() {
                    // performHandshake suspends while one write/read transaction
                    // runs on ipcQueue. A setEnabled(false) interleave during that
                    // await bumps the generation and sets socketFD = -1. Committing
                    // .connected here would wedge the service on a dead fd because
                    // connectIfNeeded and pollTick both require .disconnected.
                    // Re-validate before publishing the successful connection.
                    guard ownsConnection(fd: fd, generation: attemptGeneration), isEnabled else {
                        if ownsConnection(fd: fd, generation: attemptGeneration) {
                            await retirePreSourceConnection(
                                fd: fd,
                                generation: attemptGeneration
                            )
                        }
                        return
                    }
                    state = .connected
                    lastFailure = .none
                    reconnectDelay = AppConstants.Discord.reconnectBaseDelay
                    updateAvailabilityPolling()
                    await refreshPresenceFromSettings()
                    startIPCReadPump()
                    return
                } else {
                    guard recordHandshakeRejectionIfCurrent(fd: fd, generation: attemptGeneration) else { return }
                    Log.warn("DiscordRPCService: Handshake failed on slot \(slot)", category: .discord)
                    // A socket existed and Discord refused us, so this is not
                    // "Discord isn't running" however the loop ends.
                    // A concurrent disconnect() may already have retired the fd
                    // and reset socketFD to -1. Only close here if the fd is
                    // still ours; otherwise we'd double-close (EBADF, and a
                    // recycled fd could be hit in edge cases).
                    if ownsConnection(fd: fd, generation: attemptGeneration) {
                        await retirePreSourceConnection(
                            fd: fd,
                            generation: attemptGeneration
                        )
                    }
                    guard isEnabled, connectionGeneration == attemptGeneration else { return }
                }
            }
        }

        Log.debug("DiscordRPCService: No active IPC socket found in any candidate directory", category: .discord)
        guard isEnabled,
              connectionGeneration == attemptGeneration,
              state == .connecting else { return }
        // Only claim Discord is closed when no slot rejected us. A handshake
        // rejection recorded above outranks this.
        if lastFailure != .handshakeRejected {
            lastFailure = .notRunning
        }
        state = .disconnected
    }

    /// Result of one injected `poll` call used by the nonblocking-connect seam.
    struct IPCPollResult: Sendable {
        /// `poll(2)` return value: >0 ready, 0 timed out, <0 error.
        let count: Int32
        let revents: Int16
        /// `errno` captured right after a failing `poll`; 0 otherwise.
        let errno: Int32
    }

    /// Opens, connects, and applies timeouts to a Unix-domain socket at
    /// `socketPath`. Pure of actor state so it can run on ``ipcQueue`` (where the
    /// blocking `connect()` belongs). Returns the connected fd with send/receive
    /// timeouts applied, or -1 on any failure (closing any partial fd first).
    /// `slot` is used only for logging.
    ///
    /// The connect runs nonblocking (bounded by `socketTimeoutSeconds`) so a
    /// wedged listener cannot hang the queue, then the original blocking flags
    /// are restored. Paths longer than `sun_path` are rejected rather than
    /// truncated.
    nonisolated static func openIPCSocket(at socketPath: String, slot: Int) -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return -1 }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)

        let pathBytes = socketPath.utf8CString
        guard pathBytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else {
            Darwin.close(fd)
            return -1
        }

        withUnsafeMutablePointer(to: &addr.sun_path) { sunPathPtr in
            sunPathPtr.withMemoryRebound(to: CChar.self, capacity: pathBytes.count) { dest in
                pathBytes.withUnsafeBufferPointer { src in
                    guard let srcBase = src.baseAddress else { return }
                    _ = memcpy(dest, srcBase, pathBytes.count)
                }
            }
        }

        let originalFlags = fcntl(fd, F_GETFL, 0)
        guard originalFlags >= 0,
              fcntl(fd, F_SETFL, originalFlags | O_NONBLOCK) == 0 else {
            Darwin.close(fd)
            return -1
        }

        let addrLen = socklen_t(MemoryLayout<sockaddr_un>.size)
        let result = withUnsafePointer(to: &addr) { addrPtr in
            addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                Darwin.connect(fd, sockaddrPtr, addrLen)
            }
        }

        let connectError: Int32
        if result == 0 {
            connectError = 0
        } else {
            let immediateError = errno
            if immediateError == EINPROGRESS {
                connectError = waitForNonblockingConnect(
                    fd: fd,
                    deadline: monotonicDeadline(
                        afterNanoseconds: UInt64(AppConstants.Discord.socketTimeoutSeconds)
                            * 1_000_000_000
                    ),
                    now: monotonicNow,
                    poller: systemPollForWrite,
                    socketError: pendingSocketError
                )
            } else {
                connectError = immediateError
            }
        }

        let restoreResult = fcntl(fd, F_SETFL, originalFlags)
        guard connectError == 0, restoreResult == 0 else {
            let err = connectError != 0 ? connectError : errno
            Log.debug("DiscordRPCService: connect() failed on slot \(slot): errno \(err) (\(String(cString: strerror(err))))", category: .discord)
            Darwin.close(fd)
            return -1
        }

        guard setSocketTimeouts(fd) else {
            Darwin.close(fd)
            return -1
        }
        return fd
    }

    /// Waits for a nonblocking connect to finish within an absolute monotonic
    /// deadline. `poller`, `socketError`, and `now` are injected so timeout and
    /// error handling are deterministic in unit tests without a live socket.
    ///
    /// - Returns: 0 when connected, `ETIMEDOUT` when the deadline passes, the
    ///   socket's pending `SO_ERROR`, or the `poll` errno (`EIO` if none was
    ///   captured). `EINTR` retries against the same deadline.
    nonisolated static func waitForNonblockingConnect(
        fd: Int32,
        deadline: UInt64,
        now: () -> UInt64,
        poller: (Int32, Int32) -> IPCPollResult,
        socketError: (Int32) -> Int32
    ) -> Int32 {
        while true {
            let current = now()
            guard current < deadline else { return ETIMEDOUT }
            let timeout = pollTimeoutMilliseconds(deadline: deadline, now: current)
            let result = poller(fd, timeout)
            if result.count > 0 {
                return socketError(fd)
            }
            if result.count == 0 {
                return ETIMEDOUT
            }
            if result.errno == EINTR {
                continue
            }
            return result.errno == 0 ? EIO : result.errno
        }
    }

    /// Production poller for ``waitForNonblockingConnect``: one `poll(2)` for
    /// `POLLOUT`, capturing `errno` on this thread.
    private nonisolated static func systemPollForWrite(
        _ fd: Int32,
        _ timeout: Int32
    ) -> IPCPollResult {
        var descriptor = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        let count = Darwin.poll(&descriptor, nfds_t(1), timeout)
        return IPCPollResult(
            count: count,
            revents: descriptor.revents,
            errno: count < 0 ? errno : 0
        )
    }

    /// Reads and clears the socket's pending error (`SO_ERROR`), which holds the
    /// outcome of a nonblocking connect. Returns `getsockopt`'s errno if the
    /// query itself fails.
    private nonisolated static func pendingSocketError(_ fd: Int32) -> Int32 {
        var pendingError: Int32 = 0
        var size = socklen_t(MemoryLayout<Int32>.size)
        guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &pendingError, &size) == 0 else {
            return errno
        }
        return pendingError
    }

    /// Sends the RPC handshake and accepts only Discord's READY dispatch.
    ///
    /// The write and response read run in one ``ipcQueue`` block. Keeping the
    /// exchange atomic prevents another actor call from inserting a command
    /// between the handshake write and READY response.
    ///
    /// Does not tear down on failure; ``connectIfNeeded()`` owns cleanup of the
    /// pre-source fd.
    ///
    /// - Returns: True only for an opcode-``Opcode/frame`` response whose payload
    ///   has `cmd == "DISPATCH"` and `evt == "READY"`, and only if this
    ///   connection is still current when the transaction returns.
    func performHandshake() async -> Bool {
        let handshake: [String: Any] = [
            "v": AppConstants.Discord.rpcVersion,
            "client_id": clientID
        ]

        guard let outbound = Self.encodeFrame(opcode: .handshake, payload: handshake) else {
            Log.error("DiscordRPCService: Failed to serialize handshake", category: .discord)
            return false
        }

        let fd = socketFD
        guard fd >= 0 else { return false }
        let generation = connectionGeneration
        let readBuffer = ipcReadBuffer
        let timeoutNanoseconds = ipcTransactionTimeoutNanoseconds
        let result = await runOnIPCQueue {
            Self.performIPCTransaction(
                outbound,
                expecting: .ready,
                fd: fd,
                readBuffer: readBuffer,
                timeoutNanoseconds: timeoutNanoseconds
            )
        }

        // The actor was re-entrant while the blocking transaction ran. An fd
        // integer can be reused, so both fd and generation are required before
        // this continuation may inspect or mutate connection state.
        guard ownsConnection(fd: fd, generation: generation) else { return false }

        guard result.writeResult.ok else {
            let err = result.writeResult.errno
            let reason = "\(err) (\(String(cString: strerror(err))))"
            Log.error(
                "DiscordRPCService: Handshake write failed/timed out: \(reason)",
                category: .discord
            )
            return false
        }

        guard result.response != nil else {
            if result.readErrno != 0 {
                let err = result.readErrno
                let reason = "\(err) (\(String(cString: strerror(err))))"
                Log.error(
                    "DiscordRPCService: Handshake read failed/timed out: \(reason)",
                    category: .discord
                )
            } else {
                Log.warn("DiscordRPCService: Invalid handshake response; expected DISPATCH/READY", category: .discord)
            }
            return false
        }

        return true
    }

    /// Disconnects from the IPC socket.
    ///
    /// Bumps ``connectionGeneration`` so any in-flight connect that resumes after
    /// this teardown discards its fd instead of committing it. The close runs on
    /// ``ipcQueue`` so it serializes after any queued read/write still holding the
    /// captured fd, never racing them or closing a recycled descriptor.
    ///
    /// Also drops any queued presence. Returns only after the descriptor is
    /// actually closed, so a following connect can never overlap the old fd.
    func disconnect() async {
        cancelPendingPresence()
        connectionGeneration &+= 1

        guard socketFD >= 0 else {
            if state != .disconnected { state = .disconnected }
            if let pendingClose = ipcCloseInProgress {
                await pendingClose.wait()
                if ipcCloseInProgress === pendingClose {
                    ipcCloseInProgress = nil
                }
            }
            return
        }

        let fd = socketFD
        let source = ipcReadSource
        let sourceClose = ipcReadSourceClose

        // Retire every actor-visible ownership token before the first await.
        // Another disconnect or connect can now observe that this generation no
        // longer owns `fd`, even while the asynchronous cancel handler is gated.
        socketFD = -1
        ipcReadSource = nil
        ipcReadSourceClose = nil
        state = .disconnected

        let completion = sourceClose ?? IPCDescriptorClose()
        ipcCloseInProgress = completion
        let closer = ipcSocketCloser
        if let source {
            if sourceClose == nil {
                // Defensive repair for an incompletely installed test source.
                // Production installation always pairs these atomically.
                source.setCancelHandler {
                    closer(fd)
                    completion.complete()
                }
            }
            // Once installed, the source cancellation handler is the sole
            // descriptor closer. Never directly close `fd` on this path.
            source.cancel()
        } else {
            // Pre-source descriptor (normally a handshake in progress).
            ipcQueue.async {
                closer(fd)
                completion.complete()
            }
        }

        await completion.wait()
        if ipcCloseInProgress === completion {
            ipcCloseInProgress = nil
        }
    }

    /// Synchronously retires an actor-owned descriptor that has not yet gained a
    /// read source, then awaits its queue-confined close. Used by stale-success
    /// and failed-handshake paths so actor reentrancy cannot retain a recycled fd.
    private func retirePreSourceConnection(fd: Int32, generation: UInt64) async {
        guard ownsConnection(fd: fd, generation: generation) else { return }
        socketFD = -1
        ipcReadSource = nil
        ipcReadSourceClose = nil

        let completion = IPCDescriptorClose()
        ipcCloseInProgress = completion
        let closer = ipcSocketCloser
        ipcQueue.async {
            closer(fd)
            completion.complete()
        }
        await completion.wait()
        if ipcCloseInProgress === completion {
            ipcCloseInProgress = nil
        }
    }

    // MARK: - Idle Inbound Pump

    /// Result of one short, queue-owned idle read slice.
    private enum IdleReadResult: Sendable {
        /// Everything buffered was processed.
        case handled
        /// More complete frames remain than one slice handles; drain again.
        case needsDrain
        /// Peer closed, sent CLOSE, sent a malformed frame, or I/O failed.
        /// `errno` is 0 for a clean close.
        case connectionLost(errno: Int32)
    }

    /// Starts the sole unsolicited-frame reader for the current connection.
    ///
    /// The dispatch source only schedules work when the socket becomes readable,
    /// avoiding the permanent 100 ms polling loop previously used here. Its
    /// event handler runs on ipcQueue, the same serial queue as command
    /// transactions. A handler that runs first cannot steal a future command
    /// reply because that command has not yet written; a transaction that runs
    /// first owns its complete write/read exchange.
    func startIPCReadPump() {
        // Installation transfers physical fd ownership to the source's cancel
        // handler. Replacing a live source would create two potential closers,
        // so repeated starts are deliberately a no-op.
        guard ipcReadSource == nil else { return }
        guard state == .connected, socketFD >= 0 else {
            return
        }
        guard ipcCloseInProgress == nil else { return }
        let fd = socketFD
        let generation = connectionGeneration
        let readBuffer = ipcReadBuffer
        let closeCompletion = IPCDescriptorClose()
        let closer = ipcSocketCloser
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: ipcQueue)
        source.setEventHandler { [weak self] in
            let result = Self.performIdleReadSlice(fd: fd, readBuffer: readBuffer)
            switch result {
            case .handled:
                break
            case .needsDrain, .connectionLost:
                Task {
                    await self?.handleIdleReadResult(
                        result,
                        fd: fd,
                        generation: generation,
                        readBuffer: readBuffer
                    )
                }
            }
        }
        source.setCancelHandler {
            closer(fd)
            closeCompletion.complete()
        }
        ipcReadSource = source
        ipcReadSourceClose = closeCompletion
        source.resume()
    }

    /// Finishes bounded buffered draining or handles a connection loss back on
    /// the actor. Each additional drain is submitted as a fresh queue block so a
    /// command transaction already waiting on ipcQueue can run between batches.
    private func handleIdleReadResult(
        _ initialResult: IdleReadResult,
        fd: Int32,
        generation: UInt64,
        readBuffer: IPCReadBuffer
    ) async {
        var result = initialResult
        while ownsConnection(fd: fd, generation: generation), state == .connected {
            switch result {
            case .handled:
                return
            case .connectionLost(let err):
                if err != 0 {
                    Log.debug(
                        "DiscordRPCService: Idle IPC read failed: errno \(err)",
                        category: .discord
                    )
                }
                await handleConnectionLost(fd: fd, generation: generation)
                return
            case .needsDrain:
                result = await runOnIPCQueue {
                    Self.performIdleReadSlice(fd: fd, readBuffer: readBuffer)
                }
            }
        }
    }

    /// Reads one currently available byte batch and answers up to 32 complete
    /// unsolicited frames. `MSG_DONTWAIT` keeps this event handler from parking
    /// ipcQueue if DispatchSource coalesces readiness notifications.
    private nonisolated static func performIdleReadSlice(
        fd: Int32,
        readBuffer: IPCReadBuffer
    ) -> IdleReadResult {
        let deadline = monotonicDeadline(
            afterNanoseconds: UInt64(AppConstants.Discord.socketTimeoutSeconds)
                * 1_000_000_000
        )
        var bytes = [UInt8](repeating: 0, count: 16_384)
        let count = bytes.withUnsafeMutableBytes { rawBuffer -> Int in
            guard let baseAddress = rawBuffer.baseAddress else { return -1 }
            return Darwin.recv(fd, baseAddress, rawBuffer.count, Int32(MSG_DONTWAIT))
        }
        if count > 0 {
            readBuffer.data.append(contentsOf: bytes.prefix(count))
        } else if count == 0 {
            return .connectionLost(errno: 0)
        } else if errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR {
            return .connectionLost(errno: errno)
        }

        for _ in 0..<32 {
            guard let readResult = popIPCFrame(from: readBuffer) else { break }
            guard let frame = readResult.frame else {
                return .connectionLost(errno: readResult.errno)
            }
            if frame.opcode == Opcode.close.rawValue {
                return .connectionLost(errno: 0)
            }
            guard frame.opcode == Opcode.ping.rawValue else { continue }
            guard let pong = encodeRawFrame(
                opcode: .pong,
                payload: frame.payload ?? Data()
            ) else {
                return .connectionLost(errno: EMSGSIZE)
            }
            let writeResult = writeFully(pong, fd: fd, deadline: deadline)
            guard writeResult.ok else {
                return .connectionLost(errno: writeResult.errno)
            }
        }

        return hasCompleteIPCFrame(in: readBuffer) ? .needsDrain : .handled
    }

    /// Whether the queue-owned buffer contains at least one complete frame.
    /// An oversized advertised length also counts as complete so the next drain
    /// reports the malformed frame instead of leaving it buffered forever.
    private nonisolated static func hasCompleteIPCFrame(in readBuffer: IPCReadBuffer) -> Bool {
        guard readBuffer.data.count >= 8 else { return false }
        let length = readBuffer.data.withUnsafeBytes { buffer in
            UInt32(littleEndian: buffer.loadUnaligned(fromByteOffset: 4, as: UInt32.self))
        }
        guard length < AppConstants.Discord.maxIPCFrameBytes else { return true }
        return readBuffer.data.count >= 8 + Int(length)
    }

    /// Connection ownership predicate. Descriptor integers alone are unsafe:
    /// the OS may recycle one for a replacement socket after a teardown.
    nonisolated static func isCurrentConnection(
        capturedFD: Int32,
        capturedGeneration: UInt64,
        currentFD: Int32,
        currentGeneration: UInt64
    ) -> Bool {
        capturedFD >= 0
            && capturedFD == currentFD
            && capturedGeneration == currentGeneration
    }

    /// Whether `(fd, generation)` captured before an await still identifies
    /// the live connection.
    func ownsConnection(fd: Int32, generation: UInt64) -> Bool {
        Self.isCurrentConnection(
            capturedFD: fd,
            capturedGeneration: generation,
            currentFD: socketFD,
            currentGeneration: connectionGeneration
        )
    }

    // MARK: - Reconnection

    /// Computes the next exponential-backoff delay: doubles `current` and clamps
    /// to `max`. Pure and `nonisolated` so the backoff math is unit-testable
    /// without the actor. Reset is just `AppConstants.Discord.reconnectBaseDelay`.
    nonisolated static func nextBackoff(
        _ current: TimeInterval, max: TimeInterval
    ) -> TimeInterval {
        Swift.min(current * 2, max)
    }

    /// Handles a lost connection by disconnecting and scheduling reconnect.
    ///
    /// Ignored for a stale `(fd, generation)`. The reconnect fires after the
    /// current ``reconnectDelay``, which then doubles up to `reconnectMaxDelay`;
    /// a successful connect resets it. The availability poll also runs while
    /// disconnected, so whichever fires first reconnects.
    func handleConnectionLost(fd: Int32, generation: UInt64) async {
        guard ownsConnection(fd: fd, generation: generation) else { return }
        await disconnect()
        // The coarse availability fallback is useful only while disconnected;
        // successful connect paths stop it again immediately.
        updateAvailabilityPolling()

        guard isEnabled else { return }

        let delay = reconnectDelay
        Log.info("DiscordRPCService: Scheduling reconnect in \(delay)s", category: .discord)
        reconnectTask?.cancel()
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self else { return }
            await self.attemptReconnect()
        }

        reconnectDelay = Self.nextBackoff(
            reconnectDelay,
            max: AppConstants.Discord.reconnectMaxDelay)
    }

    /// Reconnect timer body: connects if the service is still enabled.
    private func attemptReconnect() async {
        guard isEnabled else { return }
        await connectIfNeeded()
    }
}
