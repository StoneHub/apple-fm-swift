import Testing
import Foundation
import FoundationModels
@testable import AppleFM

private enum SecretModelError: Error {
    case secretPayload
}

private actor InvocationRecorder {
    private(set) var count = 0

    func recordInvocation() {
        count += 1
    }
}

@Test func requestRoundTrip() throws {
    let request = CompletionRequest(id: "fixture", kind: "terminal", language: "zsh", before: "git sta", after: "")
    let data = try JSONEncoder().encode(request)
    #expect(try JSONDecoder().decode(CompletionRequest.self, from: data) == request)
}

@Test func emptyRequestDoesNotInvokeModel() async {
    let result = await AppleFMClient().complete(CompletionRequest(id: "empty", kind: "editor", language: "swift", before: "", after: ""))
    #expect(result == CompletionResult(id: "empty", status: .empty))
}

@Test func availabilityRawValuesPreserveLegacyStrings() {
    #expect(AppleFMAvailability.available.rawValue == "available")
    #expect(AppleFMAvailability.unsupportedOS.rawValue == "unsupported_os")
    #expect(AppleFMAvailability.deviceNotEligible.rawValue == "device_not_eligible")
    #expect(AppleFMAvailability.appleIntelligenceNotEnabled.rawValue == "apple_intelligence_not_enabled")
    #expect(AppleFMAvailability.modelNotReady.rawValue == "model_not_ready")
    #expect(AppleFMAvailability.unavailable.rawValue == "unavailable")
    #expect(AppleFMClient().availability() == AppleFMClient().modelAvailability.rawValue)
}

@Test func runnerChecksCancellationBeforeAvailabilityAndOperation() async {
    let recorder = InvocationRecorder()
    let task = Task {
        withUnsafeCurrentTask { $0?.cancel() }
        _ = try await AppleFMGenerationRunner.run(availability: {
            Issue.record("availability must not be read after pre-cancellation")
            return .available
        }) {
            await recorder.recordInvocation()
            return "unexpected"
        }
    }
    task.cancel()

    do {
        _ = try await task.value
        Issue.record("pre-cancelled request unexpectedly succeeded")
    } catch is CancellationError {
        // Expected: cancellation is propagated without model work.
    } catch {
        Issue.record("unexpected error: \(error)")
    }
    #expect(await recorder.count == 0)
}

@Test func runnerMapsAvailabilityWithoutInvokingOperation() async {
    let recorder = InvocationRecorder()
    let unavailable: [AppleFMAvailability] = [
        .unsupportedOS,
        .deviceNotEligible,
        .appleIntelligenceNotEnabled,
        .modelNotReady,
        .unavailable
    ]
    for expected in unavailable {
        do {
            _ = try await AppleFMGenerationRunner.run(availability: { expected }) {
                await recorder.recordInvocation()
                return "unexpected"
            }
            Issue.record("unavailable model unexpectedly generated a response")
        } catch let error as AppleFMError {
            #expect(error == .unavailable(expected))
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }
    #expect(await recorder.count == 0)
}

@Test func runnerMapsRawFailuresWithoutLeakingUnderlyingError() async {
    do {
        _ = try await AppleFMGenerationRunner.run(availability: { .available }) {
            throw SecretModelError.secretPayload
        } as String
        Issue.record("failing model unexpectedly succeeded")
    } catch let error as AppleFMError {
        #expect(error == .generationFailed)
        #expect(String(describing: error) == "generationFailed")
        #expect(!String(describing: error).contains("secretPayload"))
    } catch {
        Issue.record("unexpected error: \(error)")
    }
}

@Test func runnerCancellationAfterResponseDiscardsResponse() async {
    let (started, startedContinuation) = AsyncStream<Void>.makeStream()
    let task = Task {
        try await AppleFMGenerationRunner.run(availability: { .available }) {
            startedContinuation.yield()
            try? await Task.sleep(for: .seconds(3600))
            return "late response"
        }
    }
    var iterator = started.makeAsyncIterator()
    _ = await iterator.next()
    task.cancel()

    do {
        _ = try await task.value
        Issue.record("cancelled response was returned")
    } catch is CancellationError {
        // Expected: a response produced after cancellation is discarded.
    } catch {
        Issue.record("unexpected error: \(error)")
    }
}

@Test func runnerCancellationWinsOverRawFailure() async {
    let (started, startedContinuation) = AsyncStream<Void>.makeStream()
    let task = Task {
        try await AppleFMGenerationRunner.run(availability: { .available }) {
            startedContinuation.yield()
            try? await Task.sleep(for: .seconds(3600))
            throw SecretModelError.secretPayload
        } as String
    }
    var iterator = started.makeAsyncIterator()
    _ = await iterator.next()
    task.cancel()

    do {
        _ = try await task.value
        Issue.record("cancelled failing response unexpectedly succeeded")
    } catch is CancellationError {
        // Expected: cancellation wins over an underlying model failure.
    } catch {
        Issue.record("unexpected error: \(error)")
    }
}

@Test func legacyInvalidKindStillReturnsStructuredError() async {
    let request = CompletionRequest(id: "bad-kind", kind: "other", language: "text", before: "input", after: "")
    let result = await AppleFMClient().complete(request)
    #expect(result == CompletionResult(id: "bad-kind", status: .error, reason: "kind must be terminal or editor"))
}

@Test func legacyContextLimitStillReturnsStructuredError() async {
    let request = CompletionRequest(
        id: "too-large",
        kind: "editor",
        language: "text",
        before: String(repeating: "x", count: AppleFMClient.maximumContextCharacters + 1),
        after: ""
    )
    let result = await AppleFMClient().complete(request)
    #expect(result == CompletionResult(id: "too-large", status: .error, reason: "context exceeds 6000 characters"))
}

@Test func commentModeDecodesAndAsksForCommentText() throws {
    let json = ##"{"id":"c","kind":"editor","language":"ruby","before":"# Returns the ","after":"","mode":"comment"}"##
    let request = try JSONDecoder().decode(CompletionRequest.self, from: Data(json.utf8))
    #expect(request.mode == "comment")
    #expect(AppleFMClient.instruction(for: request).contains("inside a ruby comment"))
    let legacyJSON = #"{"id":"l","kind":"editor","language":"ruby","before":"x","after":""}"#
    let legacy = try JSONDecoder().decode(CompletionRequest.self, from: Data(legacyJSON.utf8))
    #expect(legacy.mode == nil)
    #expect(!AppleFMClient.instruction(for: legacy).contains("comment"))
}

@Test func completionsUseGreedySamplingWithAKindSizedCap() throws {
    guard #available(macOS 26.0, *) else { return }
    let editor = CompletionRequest(id: "e", kind: "editor", language: "ruby", before: "x", after: "")
    let comment = CompletionRequest(id: "c", kind: "editor", language: "ruby", before: "# x", after: "", mode: "comment")
    let terminal = CompletionRequest(id: "t", kind: "terminal", language: "zsh", before: "git sta", after: "")
    #expect(AppleFMClient.options(for: editor) == GenerationOptions(samplingMode: .greedy, maximumResponseTokens: 160))
    #expect(AppleFMClient.options(for: comment) == GenerationOptions(samplingMode: .greedy, maximumResponseTokens: 48))
    #expect(AppleFMClient.options(for: terminal) == GenerationOptions(samplingMode: .greedy, maximumResponseTokens: 48))
}

@Test func completionPromptUsesCursorMarkerInsteadOfEchoableLabels() {
    let request = CompletionRequest(
        id: "prompt",
        kind: "editor",
        language: "ruby",
        before: "format_price(",
        after: ")",
        context: "The argument is a price."
    )

    let prompt = AppleFMClient.prompt(for: request)
    #expect(prompt.contains("Text before <CURSOR>:\nformat_price("))
    #expect(prompt.contains("\n<CURSOR>\nText after <CURSOR>:\n)"))
    #expect(prompt.contains("Bounded context:\nThe argument is a price."))
    #expect(!prompt.contains("Prefix:"))
    #expect(!prompt.contains("Suffix:"))
}
