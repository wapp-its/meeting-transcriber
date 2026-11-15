#if !APPSTORE
    @testable import MeetingTranscriber
    import XCTest

    /// `/state.audioDevicesWindow` and the two debug actions, through the
    /// wired debug server's route handler (no port is bound).
    @MainActor
    final class AudioDevicesRPCTests: XCTestCase {
        private static let token = "audio-devices-token"

        /// A Core Audio reading that does not return until the test ends, as
        /// when coreaudiod stops answering. On the main thread it returns at
        /// once, so a read moved there fails the test instead of hanging it.
        private final class BlockedRead: @unchecked Sendable {
            private let lock = NSLock()
            private let gate = DispatchSemaphore(value: 0)
            private var countStorage = 0
            var count: Int {
                lock.withLock { countStorage }
            }

            func read(_: [pid_t]) -> AudioDeviceStatusReading {
                lock.withLock { countStorage += 1 }
                if !Thread.isMainThread { gate.wait() }
                return AudioDeviceStatusReading(running: [:], selfRunningInput: true, meetingApp: nil)
            }

            func release() {
                gate.signal()
            }
        }

        private func makeState(read: BlockedRead) throws -> AppState {
            let blocked: AudioDevicesWindowReader.Read = { read.read($0) }
            let state = try AppState(
                pipelineEnvironment: makeIsolatedPipelineEnvironment(), settings: makeIsolatedSettings(),
                audioDeviceRead: blocked,
            )
            addTeardownBlock { @MainActor in
                state.audioDevices.windowClosed()
                read.release()
            }
            return state
        }

        private func request(_ method: String, _ path: String) -> HTTPRequest {
            HTTPRequest(method: method, path: path, headers: ["authorization": "Bearer \(Self.token)"], body: Data())
        }

        /// `/state` through the route handler: the decoded field and the
        /// field's raw JSON.
        private func audioDevicesWindow(
            of server: DebugRPCServer,
        ) async throws -> (decoded: AudioDevicesWindowSnapshot, json: [String: Any]) {
            let response = await server.route(request("GET", "/state"))
            XCTAssertEqual(response.status, 200)
            let decoded = try JSONDecoder().decode(RPCStateSnapshot.self, from: response.body).audioDevicesWindow
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: response.body) as? [String: Any])
            return try (decoded, XCTUnwrap(object["audioDevicesWindow"] as? [String: Any]))
        }

        // MARK: - The debug actions

        /// Each action posts what the scene and the window observe: the open
        /// goes to the scene's `bringWindowToFront`, the close to the window's
        /// `dismissWindow`.
        func testTheTwoDebugActionsPostTheWindowsOpenAndCloseRequests() async throws {
            let server = try makeState(read: BlockedRead()).buildDebugRPCServer(port: 0, token: Self.token)
            let cases: [(path: String, name: Notification.Name)] = [
                ("/action/openAudioDevices", .showAudioDevices), ("/action/closeAudioDevices", .closeAudioDevices),
            ]
            for testCase in cases {
                let posted = expectation(forNotification: testCase.name, object: nil)

                let response = await server.route(request("POST", testCase.path))

                XCTAssertEqual(response.status, 200, testCase.path)
                await fulfillment(of: [posted], timeout: 1)
            }
        }

        // MARK: - /state

        /// Closed: `open:false`, no rows, `selfRunningInput` null. Open while
        /// the first reading hangs: `/state` still answers, without a Core
        /// Audio call of its own, every device row reads unknown and
        /// `selfRunningInput` stays null; and closing it gives the closed
        /// field again.
        func testStateAnswersWhileTheReadingHangsAndReportsTheWindowOpenAndClosed() async throws {
            let read = BlockedRead()
            let state = try makeState(read: read)
            let server = state.buildDebugRPCServer(port: 0, token: Self.token)

            let closed = try await audioDevicesWindow(of: server)
            XCTAssertEqual(closed.decoded, .closed)
            XCTAssertTrue(closed.json["selfRunningInput"] is NSNull, "written as null: \(closed.json)")
            XCTAssertEqual(read.count, 0)

            state.audioDevices.windowOpened()
            await waitFor(read.count == 1, timeout: .seconds(2))
            let open = try await audioDevicesWindow(of: server)
            let again = try await audioDevicesWindow(of: server)

            XCTAssertTrue(open.decoded.open)
            XCTAssertEqual(open.decoded.rows.map(\.name), state.audioDevicesWindowState.rows.map(\.name))
            XCTAssertTrue(
                open.decoded.rows.allSatisfy { $0.marks.contains("unknown") || $0.marks == ["notConnected"] },
                "\(open.decoded.rows)",
            )
            XCTAssertNil(open.decoded.selfRunningInput)
            XCTAssertTrue(open.json["selfRunningInput"] is NSNull)
            XCTAssertEqual(again.decoded, open.decoded)
            XCTAssertEqual(read.count, 1, "building /state read nothing")

            state.audioDevices.windowClosed()
            let reclosed = try await audioDevicesWindow(of: server)
            XCTAssertEqual(reclosed.decoded, .closed)
        }

        /// A row's JSON: `meetingApp` null unless the row carries the mark,
        /// `litSegments` only with a bar, "Unnamed device" in place of a UID.
        func testARowsJSONWritesMeetingAppAsNullAndLeavesLitSegmentsOutWithoutABar() throws {
            let uid = "AppleUSBAudioEngine:Vendor:Headset:SERIAL123:1"
            let headset = OutputDevice(uid: uid, name: uid)
            let windowState = AudioDevicesWindowState(AudioDevicesWindowState.Inputs(
                microphones: [MicrophoneDevice(uid: "MicUID", name: "USB Microphone")], defaultInputUID: nil,
                configuredMicrophoneUID: "", outputs: [headset], defaultOutput: nil, meetingAppHint: nil,
                recording: AudioDevicesWindowState.Recording(
                    capturesApp: true, appName: "Teams", recordedMicrophoneUID: "MicUID", paused: false,
                    micLitSegments: 7, appLitSegments: 4,
                ),
                status: AudioDeviceStatus(
                    running: ["MicUID": true, uid: false],
                    meetingApp: MeetingAppDevices(inputUIDs: [], outputUIDs: [uid], inputComplete: true, outputComplete: true),
                ),
            ))
            let snapshot = AudioDevicesWindowSnapshot(state: windowState, selfRunningInput: false)

            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(snapshot)) as? [String: Any])
            let rows = try XCTUnwrap(object["rows"] as? [[String: Any]])

            XCTAssertEqual(object["open"] as? Bool, true)
            XCTAssertEqual(object["selfRunningInput"] as? Bool, false)
            XCTAssertEqual(rows.map { $0["group"] as? String }, ["microphone", "output", "meetingAudio"])
            XCTAssertEqual(rows.map { $0["name"] as? String }, ["USB Microphone", "Unnamed device", "Teams"])
            XCTAssertEqual(rows.map { $0["marks"] as? [String] }, [["recording", "inUse"], ["meetingApp"], ["recording"]])
            XCTAssertTrue(rows[0]["meetingApp"] is NSNull)
            XCTAssertEqual(rows[1]["meetingApp"] as? String, "Teams")
            XCTAssertEqual(rows.map { $0["levelBar"] as? Bool }, [true, false, true])
            XCTAssertEqual(rows.map { $0["litSegments"] as? Int }, [7, nil, 4])
            XCTAssertFalse(rows[1].keys.contains("litSegments"))
        }
    }
#endif
