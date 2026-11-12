import CoreML
import Foundation
import WhisperKit

/// WhisperKit's segment seeker with the word alignment corrected for the
/// vocabulary prompt.
///
/// WhisperKit 1.1.1 feeds a prompted decode `<|startofprev|>`, the prompt
/// tokens, then `<|startoftranscript|>` and the rest, and writes one alignment
/// row per token it fed, but returns the tokens only from
/// `<|startoftranscript|>` on. Its word alignment
/// (`SegmentSeeker.addWordTimestamps`) reads the rows from the first one, so
/// with a prompt every word is matched to the attention of a token one prompt
/// length earlier: segments land seconds off and whole turns go missing. This
/// seeker drops the prompt's rows before WhisperKit aligns the words and
/// forwards everything else unchanged. Once WhisperKit fixes the offset itself
/// this shifts twice, which `WhisperKitWordTimestampsTests` catches.
struct PromptAlignedSegmentSeeker: SegmentSeeking {
    private let seeker = SegmentSeeker()

    // The two requirements' signatures are WhisperKit's `SegmentSeeking`.
    // swiftlint:disable function_parameter_count discouraged_optional_collection

    func findSeekPointAndSegments(
        decodingResult: DecodingResult,
        options: DecodingOptions,
        allSegmentsCount: Int,
        currentSeek seek: Int,
        segmentSize: Int,
        sampleRate: Int,
        timeToken: Int,
        specialToken: Int,
        tokenizer: any WhisperTokenizer,
    ) -> (Int, [TranscriptionSegment]?) {
        seeker.findSeekPointAndSegments(
            decodingResult: decodingResult,
            options: options,
            allSegmentsCount: allSegmentsCount,
            currentSeek: seek,
            segmentSize: segmentSize,
            sampleRate: sampleRate,
            timeToken: timeToken,
            specialToken: specialToken,
            tokenizer: tokenizer,
        )
    }

    func addWordTimestamps(
        segments: [TranscriptionSegment],
        alignmentWeights: MLMultiArray,
        tokenizer: any WhisperTokenizer,
        seek: Int,
        segmentSize: Int,
        prependPunctuations: String,
        appendPunctuations: String,
        lastSpeechTimestamp: Float,
        options: DecodingOptions,
        timings: TranscriptionTimings,
    ) throws -> [TranscriptionSegment]? {
        let promptRows = Self.promptRowCount(for: options, specialTokenBegin: tokenizer.specialTokens.specialTokenBegin)
        // An alignment layout this seeker cannot shift keeps segment-level
        // times, as a model without alignment data does, rather than failing.
        guard let alignedWeights = try Self.droppingLeadingRows(promptRows, of: alignmentWeights) else {
            return segments
        }
        return try seeker.addWordTimestamps(
            segments: segments,
            alignmentWeights: alignedWeights,
            tokenizer: tokenizer,
            seek: seek,
            segmentSize: segmentSize,
            prependPunctuations: prependPunctuations,
            appendPunctuations: appendPunctuations,
            lastSpeechTimestamp: lastSpeechTimestamp,
            options: options,
            timings: timings,
        )
    }

    // swiftlint:enable function_parameter_count discouraged_optional_collection

    /// How many alignment rows the prompt takes ahead of
    /// `<|startoftranscript|>`: the prompt tokens WhisperKit's
    /// `TextDecoder.prefillDecoderInputs` keeps (the last
    /// `maxTokenContext / 2 - 1`, without special tokens) plus
    /// `<|startofprev|>`, or none when nothing is kept, since WhisperKit then
    /// sends no prompt at all.
    static func promptRowCount(for options: DecodingOptions, specialTokenBegin: Int) -> Int {
        guard let promptTokens = options.promptTokens else { return 0 }
        let kept = promptTokens.suffix(Constants.maxTokenContext / 2 - 1).filter { $0 < specialTokenBegin }
        return kept.isEmpty ? 0 : kept.count + 1
    }

    /// `weights` (rows of tokens by columns of audio frames) with its first
    /// `count` rows removed and as many zero rows appended. A new array:
    /// WhisperKit reuses the one it passes in for the next window. Nil for a
    /// layout other than WhisperKit 1.1.1's two-dimensional, row-major one.
    static func droppingLeadingRows(_ count: Int, of weights: MLMultiArray) throws -> MLMultiArray? {
        guard count > 0 else { return weights }
        guard weights.shape.count == 2, weights.strides[1].intValue == 1,
              let elementBytes = elementSize(of: weights.dataType)
        else { return nil }
        let rows = weights.shape[0].intValue
        let rowBytes = weights.shape[1].intValue * elementBytes
        let sourceRowStride = weights.strides[0].intValue * elementBytes
        let shifted = try MLMultiArray(shape: weights.shape, dataType: weights.dataType)
        weights.withUnsafeBytes { source in
            shifted.withUnsafeMutableBytes { destination, strides in
                guard let from = source.baseAddress, let to = destination.baseAddress else { return }
                let destinationRowStride = strides[0] * elementBytes
                for row in 0 ..< rows {
                    let target = to + row * destinationRowStride
                    if row + count < rows {
                        target.copyMemory(from: from + (row + count) * sourceRowStride, byteCount: rowBytes)
                    } else {
                        target.initializeMemory(as: UInt8.self, repeating: 0, count: rowBytes)
                    }
                }
            }
        }
        return shifted
    }

    private static func elementSize(of dataType: MLMultiArrayDataType) -> Int? {
        switch dataType {
        case .float16: 2
        case .float32, .int32: 4
        case .double: 8
        default: nil
        }
    }
}
