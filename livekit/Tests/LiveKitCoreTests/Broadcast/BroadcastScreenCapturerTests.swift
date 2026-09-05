/*
 * Copyright 2026 LiveKit
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

#if os(iOS)

import Foundation
@testable import LiveKit
import Testing

@Suite(.tags(.broadcast))
@MainActor
struct BroadcastScreenCapturerTests {
    private struct Header: Codable {}

    private enum TestError: Error {
        case listenerDidNotStart
        case unexpectedAudioDemand
    }

    @available(iOS 16.0, *)
    @Test(.timeLimit(.minutes(1))) func stopBeforeExtensionConnectsJoinsListenerAndReleasesCapturer() async throws {
        let path = try makeSocketPath()
        var capturer: BroadcastScreenCapturer? = makeCapturer(socketPath: path)
        weak var releasedCapturer = capturer
        #expect(try await capturer?.startCapture() == true)
        try await waitForListener(path)
        #expect(try await capturer?.stopCapture() == true)
        print("[BroadcastLifecycleTest] listener-only stop joined")
        capturer = nil
        #expect(releasedCapturer == nil)

        let replacement = makeCapturer(socketPath: path)
        #expect(try await replacement.startCapture())
        let extensionChannel = try await IPCChannel(connectingTo: path)
        defer { extensionChannel.close() }
        print("[BroadcastLifecycleTest] replacement peer connected")
        #expect(try await replacement.stopCapture())
        print("[BroadcastLifecycleTest] replacement stop joined; waiting for peer EOF")
        let terminalMessage = try await extensionChannel.incomingMessages(Header.self).next()
        #expect(terminalMessage == nil)
    }

    @available(iOS 16.0, *)
    @Test(.timeLimit(.minutes(1))) func stopConnectedReceiverJoinsBlockedSampleRead() async throws {
        let path = try makeSocketPath()
        let capturer = makeCapturer(socketPath: path, appAudio: true)
        #expect(try await capturer.startCapture())
        let extensionChannel = try await IPCChannel(connectingTo: path)
        defer { extensionChannel.close() }

        print("[BroadcastLifecycleTest] peer connected")
        // The receiver sends audio demand only after it owns the accepted connection. This
        // exercises a blocked sample read separately from the immediate-stop connection race.
        let demand = try await extensionChannel.incomingMessages(BroadcastIPCHeader.self).next()
        let (header, _) = try #require(demand)
        guard case .wantsAudio(true) = header else { throw TestError.unexpectedAudioDemand }
        print("[BroadcastLifecycleTest] receiver handshake completed")
        #expect(try await capturer.stopCapture())
        print("[BroadcastLifecycleTest] receiver stop joined; waiting for peer EOF")
        #expect(capturer.captureState == .stopped)
        let terminalMessage = try await extensionChannel.incomingMessages(Header.self).next()
        #expect(terminalMessage == nil)
    }

    @available(iOS 16.0, *)
    @Test(.timeLimit(.minutes(1))) func oldReceiverCompletionCannotStopReplacementCapture() async throws {
        let path = try makeSocketPath()
        let capturer = makeCapturer(socketPath: path)
        for _ in 0 ..< 20 {
            #expect(try await capturer.startCapture())
            let oldChannel = try await IPCChannel(connectingTo: path)
            oldChannel.close()
            _ = try await capturer.stopCapture()

            #expect(try await capturer.startCapture())
            let replacementChannel = try await IPCChannel(connectingTo: path)
            #expect(capturer.captureState == .started)
            #expect(try await capturer.stopCapture())
            print("[BroadcastLifecycleTest] generation stop joined; waiting for peer EOF")
            let terminalMessage = try await replacementChannel.incomingMessages(Header.self).next()
            #expect(terminalMessage == nil)
            replacementChannel.close()
        }
    }

    private func makeSocketPath() throws -> SocketPath {
        #expect(FileManager.default.changeCurrentDirectoryPath(FileManager.default.temporaryDirectory.path))
        return try #require(SocketPath("lk-capture-\(UUID().uuidString).sock"))
    }

    private func makeCapturer(socketPath: SocketPath, appAudio: Bool = false) -> BroadcastScreenCapturer {
        let source = RTC.createVideoSource(forScreenShare: true)
        return BroadcastScreenCapturer(
            delegate: source,
            options: ScreenShareCaptureOptions(appAudio: appAudio, useBroadcastExtension: true),
            socketPath: socketPath,
        )
    }

    @available(iOS 16.0, *)
    private func waitForListener(_ path: SocketPath) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !FileManager.default.fileExists(atPath: path.path) {
            guard ContinuousClock.now < deadline else { throw TestError.listenerDidNotStart }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }
}

#endif
