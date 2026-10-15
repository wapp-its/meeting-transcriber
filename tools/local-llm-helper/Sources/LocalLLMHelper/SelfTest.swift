import Darwin
import MLX

/// `selftest`: proves, without a model, that MLX finds its compiled Metal
/// shaders (the `mlx-swift_Cmlx.bundle` SwiftPM builds next to the binary)
/// and computes correctly on the GPU. Each GPU result is compared with the
/// same operation on the CPU. A few MB of arrays, under a second.
///
/// Exit status 0 when every check passes, 1 otherwise. A shader library that
/// cannot be found is reported by MLX as an error, which ends the test as a
/// failure rather than a crash.
enum SelfTest {
    static func run() -> Never {
        Console.out("device: \(GPU.deviceInfo().architecture)")
        var failures = 0
        do {
            try withError {
                failures += matrixChecks()
                failures += shaderLibraryChecks()
            }
        } catch {
            failures += 1
            Console.out("FAIL MLX error: \(error)")
        }
        if failures > 0 {
            Console.out("SELFTEST FAILED: \(failures) check(s)")
            _exit(1)
        }
        Console.out("SELFTEST OK")
        _exit(0)
    }

    /// Prints the comparison and returns 1 when it fails, 0 when it passes.
    private static func check(_ name: String, _ gpu: MLXArray, _ cpu: MLXArray, tolerance: Float) -> Int {
        let difference = MLX.abs(gpu.asType(.float32) - cpu.asType(.float32)).max().item(Float.self)
        let passed = difference.isFinite && difference <= tolerance
        Console.out("\(passed ? "ok  " : "FAIL") \(name): max |gpu - cpu| = \(difference)")
        return passed ? 0 : 1
    }

    private static func pattern(_ shape: [Int], modulo: Float, offset: Float) -> MLXArray {
        ((MLX.arange(shape.reduce(1, *), dtype: .float32) % modulo) - offset).reshaped(shape) * 0.1
    }

    /// Plain and 4-bit quantised matrix multiplies, the latter in bfloat16 as
    /// a quantised model's linear layers run it.
    private static func matrixChecks() -> Int {
        let x = pattern([512, 512], modulo: 13, offset: 6)
        let y = pattern([512, 512], modulo: 7, offset: 3)
        var failures = check("matmul 512x512", MLX.matmul(x, y, stream: .gpu), MLX.matmul(x, y, stream: .cpu), tolerance: 1e-2)

        let input = x.asType(.bfloat16)
        let (weights, scales, biases) = MLX.quantized(y.asType(.bfloat16), groupSize: 64, bits: 4, stream: .cpu)
        func quantizedProduct(_ stream: StreamOrDevice) -> MLXArray {
            MLX.quantizedMM(input, weights, scales: scales, biases: biases, transpose: true, groupSize: 64, bits: 4, stream: stream)
        }
        failures += check("quantized matmul bf16 4-bit", quantizedProduct(.gpu), quantizedProduct(.cpu), tolerance: 0.5)
        return failures
    }

    /// Kernels that exist only in the compiled shader library.
    private static func shaderLibraryChecks() -> Int {
        let hidden = pattern([8, 1024], modulo: 11, offset: 5)
        let scale = MLX.ones([1024], dtype: .float32) * 1.5
        var failures = check(
            "rms_norm",
            MLXFast.rmsNorm(hidden, weight: scale, eps: 1e-6, stream: .gpu),
            MLXFast.rmsNorm(hidden, weight: scale, eps: 1e-6, stream: .cpu),
            tolerance: 1e-3,
        )
        let rotated = pattern([1, 4, 16, 64], modulo: 9, offset: 4)
        failures += check(
            "rope",
            MLXFast.RoPE(rotated, dimensions: 64, traditional: false, base: 10000, scale: 1, offset: 3, stream: .gpu),
            MLXFast.RoPE(rotated, dimensions: 64, traditional: false, base: 10000, scale: 1, offset: 3, stream: .cpu),
            tolerance: 1e-3,
        )
        let keys = pattern([1, 4, 128, 64], modulo: 5, offset: 2).asType(.bfloat16)
        let values = pattern([1, 4, 128, 64], modulo: 3, offset: 1).asType(.bfloat16)
        for queries in [1, 64] {
            let query = pattern([1, 4, queries, 64], modulo: 7, offset: 3).asType(.bfloat16)
            func attention(_ stream: StreamOrDevice) -> MLXArray {
                MLXFast.scaledDotProductAttention(queries: query, keys: keys, values: values, scale: 0.125, mask: nil, stream: stream)
            }
            failures += check("attention bf16 q=\(queries)", attention(.gpu), attention(.cpu), tolerance: 2e-2)
        }
        return failures
    }
}
