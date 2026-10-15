#if !APPSTORE

    @testable import MeetingTranscriber
    import XCTest

    /// The memory figures and the guard's two thresholds (spec R4, A9), from raw
    /// `vm_statistics64` counts and from injected readings. The gate's use of
    /// them against a running fake helper is in `LocalModelGateTests`.
    final class LocalModelMemoryGuardTests: XCTestCase {
        private static let pageSize: UInt64 = 16384
        private static let weights: UInt64 = 8 << 30

        func testOnlyFreeAndInactivePagesCountAsAvailable() {
            // 48 GiB of other apps' working sets, 2 GiB free and 3 GiB inactive:
            // the Mac looks large, but only 5 GiB can be handed out.
            let statistics = Self.statistics(free: 2 << 30, inactive: 3 << 30, active: 48 << 30)

            let available = SystemMemoryProbe.availableBytes(from: statistics, pageSize: Self.pageSize)

            XCTAssertEqual(available, 5 << 30)
            XCTAssertFalse(LocalModelMemoryGuard.admits(weightBytes: Self.weights, reading: .init(pressure: .normal, availableBytes: available)))
        }

        /// `free_count` already holds the speculative pages. One page below each
        /// boundary, adding them again would carry the figure across it.
        func testSpeculativePagesInsideTheFreeCountAreNotCountedTwice() {
            let speculative: UInt64 = 1 << 30
            let needed = Self.weights + LocalModelMemoryGuard.admissionHeadroomBytes
            let floor = LocalModelMemoryGuard.terminationFloorBytes
            let free: UInt64 = 2 << 30

            let belowAdmission = SystemMemoryProbe.availableBytes(
                from: Self.statistics(free: free, inactive: needed - free - Self.pageSize, speculative: speculative), pageSize: Self.pageSize,
            )
            let belowFloor = SystemMemoryProbe.availableBytes(
                from: Self.statistics(free: free, inactive: floor - free - Self.pageSize, speculative: speculative), pageSize: Self.pageSize,
            )

            XCTAssertEqual(belowAdmission, needed - Self.pageSize)
            XCTAssertFalse(LocalModelMemoryGuard.admits(weightBytes: Self.weights, reading: .init(pressure: .normal, availableBytes: belowAdmission)))
            XCTAssertGreaterThanOrEqual(belowAdmission + speculative, needed)
            XCTAssertEqual(belowFloor, floor - Self.pageSize)
            XCTAssertTrue(LocalModelMemoryGuard.mustTerminate(.init(pressure: .normal, availableBytes: belowFloor)))
            XCTAssertGreaterThanOrEqual(belowFloor + speculative, floor)
        }

        func testAdmissionNeedsNormalPressureAndAtLeastTheWeightsPlusHeadroom() {
            let needed = Self.weights + LocalModelMemoryGuard.admissionHeadroomBytes
            let cases: [(LocalModelMemoryPressure, UInt64, Bool)] = [
                (.normal, needed, true),
                (.normal, needed - 1, false),
                (.warning, needed, false),
                (.critical, .max, false),
                (.unknown, .max, false),
            ]
            for (pressure, available, admitted) in cases {
                let reading = LocalModelMemoryReading(pressure: pressure, availableBytes: available)
                XCTAssertEqual(LocalModelMemoryGuard.admits(weightBytes: Self.weights, reading: reading), admitted, reading.logFields)
            }
            XCTAssertFalse(LocalModelMemoryGuard.admits(weightBytes: .max, reading: .init(pressure: .normal, availableBytes: .max - 1)))
        }

        func testRunningHelperIsEndedAtWarningPressureOrBelowTheFloor() {
            let floor = LocalModelMemoryGuard.terminationFloorBytes
            let cases: [(LocalModelMemoryPressure, UInt64, Bool)] = [
                (.normal, floor, false),
                (.normal, floor - 1, true),
                (.warning, .max, true),
                (.critical, .max, true),
                (.unknown, .max, true),
            ]
            for (pressure, available, terminate) in cases {
                let reading = LocalModelMemoryReading(pressure: pressure, availableBytes: available)
                XCTAssertEqual(LocalModelMemoryGuard.mustTerminate(reading), terminate, reading.logFields)
            }
        }

        func testPressureLevelsFollowTheSysctlValues() {
            let cases: [(Int32?, LocalModelMemoryPressure)] = [(1, .normal), (2, .warning), (4, .critical), (3, .unknown), (nil, .unknown)]
            for (level, pressure) in cases {
                XCTAssertEqual(LocalModelMemoryPressure(level: level), pressure, String(describing: level))
            }
        }

        /// A Hugging Face cache snapshot links every file to its blob.
        func testWeightBytesSumTheSafetensorsFilesFollowingSymlinks() throws {
            let scratch = try makeTempDirectory(prefix: "LocalModelWeights")
            let folder = scratch.appendingPathComponent("model", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
            let blob = scratch.appendingPathComponent("blob")
            try Data(count: 50).write(to: blob)
            try Data(count: 100).write(to: folder.appendingPathComponent("model-00001.safetensors"))
            try FileManager.default.createSymbolicLink(at: folder.appendingPathComponent("model-00002.safetensors"), withDestinationURL: blob)
            try FileManager.default.createSymbolicLink(
                at: folder.appendingPathComponent("dangling.safetensors"), withDestinationURL: scratch.appendingPathComponent("missing"),
            )
            try FileManager.default.createDirectory(at: folder.appendingPathComponent("nested.safetensors"), withIntermediateDirectories: false)
            try Data(count: 1000).write(to: folder.appendingPathComponent("config.json"))

            XCTAssertEqual(LocalModelMemoryGuard.weightBytes(in: folder), 150)
            XCTAssertEqual(LocalModelMemoryGuard.weightBytes(in: scratch.appendingPathComponent("absent")), 0)
        }

        func testSystemProbeReadsThisMacsFigures() {
            let reading = SystemMemoryProbe().read()

            XCTAssertNotEqual(reading.pressure, .unknown)
            XCTAssertGreaterThan(reading.availableBytes, 0)
            XCTAssertLessThanOrEqual(reading.availableBytes, ProcessInfo.processInfo.physicalMemory)
        }

        private static func statistics(free: UInt64, inactive: UInt64, active: UInt64 = 0, speculative: UInt64 = 0) -> vm_statistics64 {
            var statistics = vm_statistics64()
            statistics.free_count = natural_t(free / pageSize)
            statistics.inactive_count = natural_t(inactive / pageSize)
            statistics.active_count = natural_t(active / pageSize)
            statistics.speculative_count = natural_t(speculative / pageSize)
            return statistics
        }
    }

#endif
