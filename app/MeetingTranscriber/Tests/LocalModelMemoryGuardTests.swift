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

        /// The files the helper loads: with an index, the distinct files its
        /// `weight_map` names, in a subfolder too; without one, the top-level
        /// `*.safetensors` files. Symlinks are followed, since a Hugging Face
        /// cache snapshot links every file to its blob. A named file that is
        /// not there, or an index that cannot be read, leaves the size unknown.
        func testWeightBytesCountTheFilesTheHelperLoads() throws {
            let scratch = try makeTempDirectory(prefix: "LocalModelWeights")
            let blob = scratch.appendingPathComponent("blob")
            try Data(count: 50).write(to: blob)
            let shards = #"{"weight_map":{"a":"weights/one.safetensors","b":"weights/one.safetensors","c":"weights/two.safetensors"}}"#
            let gone = scratch.appendingPathComponent("gone")
            let cases: [(name: String, layout: WeightLayout, expected: UInt64?)] = [
                ("top level", WeightLayout(files: ["model-1.safetensors": 100, "config.json": 1000], links: ["model-2.safetensors": blob]), 150),
                // The duplicate shard counts once, the top-level file the index does not name not at all.
                (
                    "index",
                    WeightLayout(files: ["weights/one.safetensors": 30, "model.safetensors": 1000], links: ["weights/two.safetensors": blob], index: shards),
                    80,
                ),
                ("no weights", WeightLayout(files: ["config.json": 10]), 0),
                ("index naming a missing file", WeightLayout(files: ["weights/one.safetensors": 30], index: shards), nil),
                ("index that is not JSON", WeightLayout(files: ["weights/one.safetensors": 30], index: "weight_map"), nil),
                ("dangling link", WeightLayout(files: ["model-1.safetensors": 100], links: ["model-2.safetensors": gone]), nil),
            ]

            for (name, layout, expected) in cases {
                let folder = try layout.make(in: scratch.appendingPathComponent(name, isDirectory: true))
                XCTAssertEqual(LocalModelMemoryGuard.weightBytes(in: folder), expected, name)
            }
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

    /// A model folder's files for a test, by path relative to the folder:
    /// plain files of a size, symlinks to a target, and the weight index text.
    struct WeightLayout {
        var files: [String: Int] = [:]
        var links: [String: URL] = [:]
        var index: String?

        func make(in folder: URL) throws -> URL {
            let manager = FileManager.default
            try manager.createDirectory(at: folder, withIntermediateDirectories: true)
            for (path, size) in files {
                let file = folder.appendingPathComponent(path)
                try manager.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data(count: size).write(to: file)
            }
            for (path, target) in links {
                let link = folder.appendingPathComponent(path)
                try manager.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
                try manager.createSymbolicLink(at: link, withDestinationURL: target)
            }
            if let index {
                try Data(index.utf8).write(to: folder.appendingPathComponent(LocalModelMemoryGuard.weightIndexFile))
            }
            return folder
        }
    }

#endif
