import Foundation
import MLX
import MLXLLM
import MLXLMCommon

/// `run`: one protocol from the request on stdin, then exit. Every step that
/// can refuse the job runs before the weights load: the request, the model
/// folder, the prompt length, the output file.
enum RunCommand {
    static func run() async -> Never {
        Termination.shared.handleSIGTERM()
        Termination.shared.watchParent()
        HelperLog.write(.started)

        let request = readRequest()
        let folder = URL(fileURLWithPath: request.modelFolder)
        let (report, loadedTokenizer) = await ModelFolderCheck.inspect(folder)
        guard let tokenizer = loadedTokenizer else { HelperExit.now(.modelUnusable, .problems(report.problems.count)) }

        let promptTokens: [Int]
        do {
            promptTokens = try Prompt.render(tokenizer: tokenizer, system: request.systemPrompt, user: request.userPrompt)
        } catch {
            HelperExit.now(.failure, .failed(.template))
        }
        HelperLog.write(.prompt(tokens: promptTokens.count, contextLimit: request.contextLimit, outputLimit: request.outputLimit))
        guard Prompt.fits(promptTokens: promptTokens.count, outputLimit: request.outputLimit, contextLimit: request.contextLimit) else {
            HelperExit.now(.promptTooLong)
        }

        let output: OutputFile
        do {
            output = try OutputFile(path: request.outputPath)
        } catch {
            HelperExit.now(.failure, .failed(.outputFile))
        }

        Memory.cacheLimit = GenerationDefaults.cacheLimitBytes
        HelperLog.write(.loading)
        let container: ModelContainer
        do {
            container = try await LLMModelFactory.shared.loadContainer(
                from: folder, using: PreloadedTokenizerLoader(tokenizer: tokenizer),
            )
        } catch {
            HelperExit.now(.failure, .failed(.load))
        }

        let generation = Task {
            await Generation.run(container: container, promptTokens: promptTokens, request: request, output: output)
        }
        if !Termination.shared.beginGeneration(cancel: { generation.cancel() }) { generation.cancel() }
        let outcome = await generation.value
        let cause = Termination.shared.endGeneration()
        output.sync()

        switch (outcome, cause) {
        case (.finished(.stop), _):
            HelperExit.now(.written)

        case (.finished(.length), _):
            HelperExit.now(.incomplete)

        case let (_, cause?):
            HelperExit.now(.terminated, .cause(cause))

        case let (.failed(step), nil):
            HelperExit.now(.failure, .failed(step))

        case (.finished, nil), (.cancelled, nil):
            HelperExit.now(.failure, .failed(.generation))
        }
    }

    /// The request, or the exit that answers why there is none. Standard input
    /// ending before a single byte means the parent is gone.
    private static func readRequest() -> RunRequest {
        let data: Data
        do {
            data = try FileHandle.standardInput.readToEnd() ?? Data()
        } catch {
            HelperExit.now(.failure, .failed(.badRequest))
        }
        switch RunRequest.parse(data) {
        case let .request(request):
            return request

        case .empty:
            HelperExit.now(.terminated, .cause(.stdinClosed))

        case .malformed, .invalid:
            HelperExit.now(.failure, .failed(.badRequest))
        }
    }
}
