import Foundation
import MLX
import MLXLMCommon

/// The fixed generation settings of the pilot. The app chooses the context
/// and output limits per request; everything else is constant here.
enum GenerationDefaults {
    /// Qwen3's recommended sampling with thinking off, the values the trial
    /// protocols were judged with. Deliberately not read from the model's
    /// generation_config.json: for the tested model that file carries the
    /// thinking-mode values (temperature 1.0, top_p 0.95).
    static let temperature: Float = 0.7
    static let topP: Float = 0.8
    static let topK = 20
    /// Prompt tokens per prefill forward, mlx-swift-lm's own default. Stated so
    /// the prefill progress can count chunks.
    static let prefillStepSize = 512
    /// MLX keeps freed buffers for reuse up to this size. Small, because the
    /// process ends after one protocol and the pool is only ever overhead.
    static let cacheLimitBytes = 512 * 1024 * 1024
    /// A writing progress line, and an fsync of the output, every this many tokens.
    static let progressEveryTokens = 32

    static func parameters(
        contextLimit: Int,
        outputLimit: Int,
        prefillProgress: (@Sendable (Int, Int) -> Void)?,
    ) -> GenerateParameters {
        GenerateParameters(
            maxTokens: outputLimit,
            maxKVSize: contextLimit,
            temperature: temperature,
            topP: topP,
            topK: topK,
            prefill: PrefillParameters(stepSize: prefillStepSize, progress: prefillProgress),
        )
    }
}

/// Turns mlx-swift-lm's prefill callback, which counts prompt positions, into
/// "chunk n of N". The text-model path prefills all but the last position in
/// equal chunks and evaluates the last one with the first output token; that
/// final forward is counted as the last chunk. A model with its own chunking
/// can deliver more callbacks than predicted, so `n` is clamped below `N`
/// until the prompt is fully read.
struct PrefillProgress: Sendable {
    let totalPositions: Int
    let chunkLength: Int
    let totalChunks: Int

    init(totalPositions: Int, stepSize: Int = GenerationDefaults.prefillStepSize) {
        self.totalPositions = totalPositions
        let chunked = max(totalPositions - 1, 0)
        let length = PrefillParameters(stepSize: stepSize).chunkLength(forChunking: chunked) ?? max(chunked, 1)
        chunkLength = max(length, 1)
        totalChunks = (chunked + chunkLength - 1) / chunkLength + 1
    }

    func chunk(processed: Int) -> Int {
        if processed >= totalPositions { return totalChunks }
        return min(max((processed + chunkLength - 1) / chunkLength, 1), totalChunks - 1)
    }
}

enum TokenWriter {
    struct Result: Equatable {
        /// The stop reason of the stream's final event, or nil when the stream
        /// ended without one because the consuming task was cancelled.
        let stop: GenerateStopReason?
        let tokens: Int
    }

    /// Decodes the token stream into `output` until it ends. Every
    /// `GenerationDefaults.progressEveryTokens` tokens, and once at the end,
    /// it syncs the file and then reports the token count to `progress`.
    static func consume(
        _ events: AsyncStream<TokenGeneration>,
        detokenizer: inout some StreamingDetokenizer,
        output: OutputFile,
        progress: (Int) -> Void,
    ) async throws -> Result {
        var tokens = 0
        var stop: GenerateStopReason?
        for await event in events {
            switch event {
            case let .token(token):
                tokens += 1
                detokenizer.append(token: token)
                if let text = detokenizer.next() { try output.append(text) }
                if tokens.isMultiple(of: GenerationDefaults.progressEveryTokens) {
                    output.sync()
                    progress(tokens)
                }

            case let .info(info):
                stop = info.stopReason
            }
        }
        output.sync()
        if !tokens.isMultiple(of: GenerationDefaults.progressEveryTokens) { progress(tokens) }
        return Result(stop: stop, tokens: tokens)
    }
}

enum Generation {
    enum Outcome: Equatable {
        /// The token stream ended; nil when it ended without a stop reason.
        case finished(GenerateStopReason?)
        /// Cancelled before the first token, between prompt chunks.
        case cancelled
        case failed(FailureStep)
    }

    /// Prefills the prompt and writes the output. Honours the cancellation of
    /// the task it runs in, which mlx-swift-lm checks between prompt chunks;
    /// once tokens flow, the same cancellation stops the token loop.
    static func run(container: ModelContainer, promptTokens: [Int], request: RunRequest, output: OutputFile) async -> Outcome {
        let progress = PrefillProgress(totalPositions: promptTokens.count)
        let parameters = GenerationDefaults.parameters(
            contextLimit: request.contextLimit, outputLimit: request.outputLimit,
        ) { processed, _ in
            HelperLog.write(.prefill(chunk: progress.chunk(processed: processed), total: progress.totalChunks))
        }
        do {
            let stop = try await container.perform { context in
                try await generate(context: context, promptTokens: promptTokens, parameters: parameters, output: output)
            }
            return .finished(stop)
        } catch is CancellationError {
            return .cancelled
        } catch is OutputFile.Failure {
            return .failed(.outputFile)
        } catch {
            return .failed(.generation)
        }
    }

    private static func generate(
        context: ModelContext,
        promptTokens: [Int],
        parameters: GenerateParameters,
        output: OutputFile,
    ) async throws -> GenerateStopReason? {
        // Runs the chunked prefill here, in the calling task, before it returns.
        let (stream, tokenTask) = try generateTokensTask(
            input: LMInput(tokens: MLXArray(promptTokens)), parameters: parameters, context: context,
        )
        var detokenizer = NaiveStreamingDetokenizer(tokenizer: context.tokenizer)
        do {
            let result = try await withTaskCancellationHandler {
                try await TokenWriter.consume(stream, detokenizer: &detokenizer, output: output) { tokens in
                    HelperLog.write(.writing(tokens: tokens))
                }
            } onCancel: {
                tokenTask.cancel()
            }
            await tokenTask.value
            return result.stop
        } catch {
            tokenTask.cancel()
            await tokenTask.value
            throw error
        }
    }
}
