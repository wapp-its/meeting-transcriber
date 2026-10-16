#if !APPSTORE

    import Darwin
    import Foundation

    /// The system's memory pressure, from `kern.memorystatus_vm_pressure_level`.
    enum LocalModelMemoryPressure: String, Sendable {
        case normal
        case warning
        case critical
        /// The level could not be read, or is a value the kernel does not document.
        case unknown

        /// From the sysctl's value: 1 normal, 2 warning, 4 critical.
        init(level: Int32?) {
            switch level {
            case 1: self = .normal
            case 2: self = .warning
            case 4: self = .critical
            default: self = .unknown
            }
        }
    }

    /// One reading of the two figures the guard decides on.
    struct LocalModelMemoryReading: Equatable, Sendable {
        let pressure: LocalModelMemoryPressure
        /// Free plus inactive memory in bytes; 0 when it could not be read.
        let availableBytes: UInt64

        /// Content-free fields for a log line.
        var logFields: String {
            "pressure=\(pressure.rawValue) available_mb=\(availableBytes >> 20)"
        }
    }

    /// Reads the system's memory figures. A protocol so the guard can be tested
    /// with injected readings.
    protocol LocalModelMemoryProbing: Sendable {
        func read() -> LocalModelMemoryReading
    }

    /// The real probe: memory pressure from `sysctl`, available memory from
    /// `host_statistics64`.
    struct SystemMemoryProbe: LocalModelMemoryProbing {
        func read() -> LocalModelMemoryReading {
            LocalModelMemoryReading(
                pressure: LocalModelMemoryPressure(level: Self.pressureLevel()),
                availableBytes: Self.vmStatistics().map { Self.availableBytes(from: $0.statistics, pageSize: $0.pageSize) } ?? 0,
            )
        }

        /// Free plus inactive pages, in bytes: the memory the system can hand
        /// out without taking it from anyone's working set.
        ///
        /// `free_count` already includes the speculative pages (`vm_stat` prints
        /// them separately, which reads as if they were extra), so they are not
        /// added again, and neither are purgeable pages, which overlap the
        /// inactive queue. Active pages never count: they are other apps' working
        /// sets. That is also why `kern.memorystatus_level` (the "free
        /// percentage" `memory_pressure` prints) is not used: it counts active
        /// pages too, and under ordinary desktop load reads about twice this figure.
        static func availableBytes(from statistics: vm_statistics64, pageSize: UInt64) -> UInt64 {
            (UInt64(statistics.free_count) + UInt64(statistics.inactive_count)) * pageSize
        }

        private static func pressureLevel() -> Int32? {
            var level: Int32 = 0
            var size = MemoryLayout<Int32>.size
            guard sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0) == 0 else { return nil }
            return level
        }

        private static func vmStatistics() -> (statistics: vm_statistics64, pageSize: UInt64)? {
            // Every `mach_host_self()` adds a reference to the host port; the
            // watchdog reads once per poll for as long as the app runs, so each
            // reference is given back.
            let host = mach_host_self()
            defer { mach_port_deallocate(mach_task_self_, host) }
            var pageSize: vm_size_t = 0
            guard host_page_size(host, &pageSize) == KERN_SUCCESS else { return nil }
            var statistics = vm_statistics64()
            var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.stride / MemoryLayout<integer_t>.stride)
            let result = withUnsafeMutablePointer(to: &statistics) { pointer in
                pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { words in
                    host_statistics64(host, HOST_VM_INFO64, words, &count)
                }
            }
            guard result == KERN_SUCCESS else { return nil }
            return (statistics, UInt64(pageSize))
        }
    }

    /// When a helper may start and when it must be ended (spec R4, A9). The
    /// guard is the app's own, independent of the helper: MLX's memory limit
    /// stops nothing.
    ///
    /// A reading that could not be taken fails closed: an unknown pressure is
    /// not normal, and unreadable available memory reads as 0.
    enum LocalModelMemoryGuard {
        /// Free memory a start needs beyond the weights: the KV cache, the
        /// activations, and room for the rest of the Mac.
        static let admissionHeadroomBytes: UInt64 = 6 << 30
        /// Free memory below which a running helper is ended.
        static let terminationFloorBytes: UInt64 = 4 << 30

        /// Whether a helper whose weights take `weightBytes` may start: only at
        /// normal pressure, with available memory at least the weights plus the headroom.
        static func admits(weightBytes: UInt64, reading: LocalModelMemoryReading) -> Bool {
            reading.pressure == .normal && reading.availableBytes >= saturatingSum(weightBytes, admissionHeadroomBytes)
        }

        /// Whether a running helper must be ended: at warning pressure or worse,
        /// or with available memory below the floor.
        static func mustTerminate(_ reading: LocalModelMemoryReading) -> Bool {
            reading.pressure != .normal || reading.availableBytes < terminationFloorBytes
        }

        /// The index that names a sharded model's weight files.
        static let weightIndexFile = "model.safetensors.index.json"

        /// The size of the weight files the helper loads from `folder`, or nil
        /// when it cannot be told. Read by the app before any helper starts,
        /// since the admission check needs it first.
        ///
        /// The files are the ones the helper's folder check and its loader
        /// pick: with `model.safetensors.index.json`, the distinct files its
        /// `weight_map` names, relative to the folder and possibly in a
        /// subfolder; without one, every `*.safetensors` file directly in the
        /// folder. Symlinks are followed (a Hugging Face cache snapshot links
        /// every file to its blob).
        ///
        /// nil for an index that cannot be read, and for a named file that is
        /// not a regular file: a figure that leaves out weights the helper
        /// would load is the failure the admission check exists to prevent.
        static func weightBytes(in folder: URL) -> UInt64? {
            let index = folder.appendingPathComponent(weightIndexFile)
            let names: Set<String>
            if FileManager.default.fileExists(atPath: index.path) {
                guard let data = try? Data(contentsOf: index),
                      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let map = object["weight_map"] as? [String: String], !map.isEmpty
                else { return nil }
                names = Set(map.values)
            } else {
                let listed = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
                names = Set(listed.filter { $0.hasSuffix(".safetensors") })
            }
            var total: UInt64 = 0
            for name in names {
                var status = stat()
                guard stat(folder.appendingPathComponent(name).path, &status) == 0, status.st_mode & S_IFMT == S_IFREG else {
                    return nil
                }
                total = saturatingSum(total, UInt64(max(0, status.st_size)))
            }
            return total
        }

        private static func saturatingSum(_ lhs: UInt64, _ rhs: UInt64) -> UInt64 {
            let (sum, overflow) = lhs.addingReportingOverflow(rhs)
            return overflow ? .max : sum
        }
    }

#endif
