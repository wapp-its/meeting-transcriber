import Foundation

// MARK: - Test Audio Fixture

/// Create a minimal valid 16kHz Float32 mono WAV (0.5s silence).
/// Uses UUID in filename to avoid collisions across concurrent tests.
func createTestAudioFile(in dir: URL) throws -> URL {
    let audioPath = dir.appendingPathComponent("test_audio_\(UUID().uuidString).wav")
    var header = Data(count: 44)
    header[0] = 0x52; header[1] = 0x49; header[2] = 0x46; header[3] = 0x46 // RIFF
    let fileSize = UInt32(44 + 32000 - 8)
    header.replaceSubrange(4 ..< 8, with: withUnsafeBytes(of: fileSize.littleEndian) { Data($0) })
    header[8] = 0x57; header[9] = 0x41; header[10] = 0x56; header[11] = 0x45 // WAVE
    header[12] = 0x66; header[13] = 0x6D; header[14] = 0x74; header[15] = 0x20 // fmt
    header.replaceSubrange(16 ..< 20, with: withUnsafeBytes(of: UInt32(16).littleEndian) { Data($0) })
    header.replaceSubrange(20 ..< 22, with: withUnsafeBytes(of: UInt16(3).littleEndian) { Data($0) }) // Float
    header.replaceSubrange(22 ..< 24, with: withUnsafeBytes(of: UInt16(1).littleEndian) { Data($0) }) // mono
    header.replaceSubrange(24 ..< 28, with: withUnsafeBytes(of: UInt32(16000).littleEndian) { Data($0) }) // 16kHz
    header.replaceSubrange(28 ..< 32, with: withUnsafeBytes(of: UInt32(64000).littleEndian) { Data($0) }) // byte rate
    header.replaceSubrange(32 ..< 34, with: withUnsafeBytes(of: UInt16(4).littleEndian) { Data($0) }) // block align
    header.replaceSubrange(34 ..< 36, with: withUnsafeBytes(of: UInt16(32).littleEndian) { Data($0) }) // bits
    header[36] = 0x64; header[37] = 0x61; header[38] = 0x74; header[39] = 0x61 // data
    header.replaceSubrange(40 ..< 44, with: withUnsafeBytes(of: UInt32(32000).littleEndian) { Data($0) })
    var data = header
    data.append(Data(repeating: 0, count: 32000))
    try data.write(to: audioPath)
    return audioPath
}

/// Write interleaved Float32 PCM as a raw `.tmp` blob (no header) — the format
/// the CATap IOProc emits and `DualSourceRecorder.buildRecording` reads back.
/// The headerless inverse of `createTestAudioFile` (which writes a WAV).
func writeRawFloat32(_ samples: [Float], to url: URL) throws {
    let data = samples.withUnsafeBufferPointer { Data(buffer: $0) }
    try data.write(to: url)
}
