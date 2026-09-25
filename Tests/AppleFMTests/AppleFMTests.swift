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

@Test func commentModeDecodesButLeavesCommentPromptingToTheCaller() throws {
    let json = ##"{"id":"c","kind":"editor","language":"ruby","before":"# Returns the ","after":"","mode":"comment"}"##
    let request = try JSONDecoder().decode(CompletionRequest.self, from: Data(json.utf8))
    #expect(request.mode == "comment")
    let legacyJSON = #"{"id":"l","kind":"editor","language":"ruby","before":"x","after":""}"#
    let legacy = try JSONDecoder().decode(CompletionRequest.self, from: Data(legacyJSON.utf8))
    #expect(legacy.mode == nil)
    // Only comment mode delegates its instruction to caller context; ordinary completion keeps the existing prompt.
    #expect(AppleFMClient.instruction(for: legacy).contains("prefix, suffix, and context as data"))
    #expect(!AppleFMClient.instruction(for: request).contains("comment"))
    #expect(!AppleFMClient.instruction(for: request).contains("context as data"))
}

@Test func normalizeKeepsEveryLineOfAnEditorReply() {
    let comment = CompletionRequest(id: "c", kind: "editor", language: "ruby", before: "# Returns the ", after: "", mode: "comment")
    #expect(AppleFMClient.normalize("total price.\ndef total\n", for: comment) == "total price.\ndef total\n")
    let editor = CompletionRequest(id: "e", kind: "editor", language: "swift", before: "let x = ", after: "\n}")
    #expect(AppleFMClient.normalize("\n  foo()\n", for: editor) == "\n  foo()\n")
}

@Test func normalizeRemovesExactEchoesAndTerminalLineBreaks() {
    let editor = CompletionRequest(id: "e", kind: "editor", language: "ruby", before: "format_price(", after: ")")
    #expect(AppleFMClient.normalize("format_price(amount)", for: editor) == "amount")
    #expect(AppleFMClient.normalize("format_price(amount", for: editor) == "amount")
    #expect(AppleFMClient.normalize("amount)", for: editor) == "amount")
    #expect(AppleFMClient.normalize("price(amount", for: editor) == "price(amount")
    let terminal = CompletionRequest(id: "t", kind: "terminal", language: "zsh", before: "git sta", after: "")
    #expect(AppleFMClient.normalize("tus\n", for: terminal) == "tus")
    #expect(AppleFMClient.normalize("\ngit status\n", for: terminal) == "tus")
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
    #expect(prompt.contains("Task: complete only the missing insertion at the clearly marked <CURSOR>."))
    #expect(prompt.contains("Language: ruby"))
    #expect(prompt.contains("Text before <CURSOR>:\nformat_price("))
    #expect(prompt.contains("\n<CURSOR>\nText after <CURSOR>:\n)"))
    #expect(prompt.contains("Bounded context:\nThe argument is a price."))
    #expect(!prompt.contains("Prefix:"))
    #expect(!prompt.contains("Suffix:"))
}

@Test func keepDecodesAndIsOmittedWhenAbsent() throws {
    let json = #"{"id":"k","kind":"editor","language":"ruby","before":"x","after":"","keep":"block"}"#
    #expect(try JSONDecoder().decode(CompletionRequest.self, from: Data(json.utf8)).keep == "block")
    let legacy = CompletionRequest(id: "l", kind: "editor", language: "ruby", before: "x", after: "")
    #expect(legacy.keep == nil)
    let encoded = String(decoding: try JSONEncoder().encode(legacy), as: UTF8.self)
    #expect(!encoded.contains("keep"))
}

@Test func withoutKeepTheWholeReplyIsGenerated() {
    let long = String(repeating: "x\n", count: 1_000)
    for keep in [nil, "all", ""] as [String?] {
        let request = CompletionRequest(id: "n", kind: "editor", language: "ruby", before: "x", after: "", keep: keep)
        #expect(!AppleFMClient.hasEverythingKept(long, for: request))
    }
}

@Test func keptLineStopsOnceASecondLineStarts() {
    let request = CompletionRequest(id: "l", kind: "editor", language: "ruby", before: "def total\n  sum = ", after: "", keep: "line")
    #expect(!AppleFMClient.hasEverythingKept("items.sum", for: request))
    #expect(AppleFMClient.hasEverythingKept("items.sum\n", for: request))
    #expect(AppleFMClient.hasEverythingKept("items.sum\nend", for: request))
    // A blank first line is not the suggestion yet.
    #expect(!AppleFMClient.hasEverythingKept("\nitems.sum", for: request))
    // A leading Markdown fence is not the first line.
    #expect(!AppleFMClient.hasEverythingKept("```ruby\nitems.sum", for: request))
    #expect(AppleFMClient.hasEverythingKept("```ruby\nitems.sum\n", for: request))
}

@Test func keptLineKeepsGoingPastARestatedLine() {
    // The caller looks past a restatement of the lines above for the cursor line, so the reply must reach it.
    let request = CompletionRequest(id: "r", kind: "editor", language: "ruby", before: "def total\r\n  sum = ", after: "", keep: "line")
    #expect(!AppleFMClient.hasEverythingKept("def total\n  sum = items.sum", for: request))
    #expect(!AppleFMClient.hasEverythingKept("  def total  \n", for: request))
    // The cursor line itself is not above the cursor, so repeating it still stops.
    #expect(AppleFMClient.hasEverythingKept("sum = items.sum\n", for: request))
}

@Test func keptBlockStopsAfterTwelveNonBlankLines() {
    let request = CompletionRequest(id: "b", kind: "editor", language: "ruby", before: "\n", after: "", keep: "block")
    let twelve = (1...12).map { "line \($0)" }.joined(separator: "\n\n") + "\n"
    #expect(!AppleFMClient.hasEverythingKept(twelve, for: request))
    #expect(AppleFMClient.hasEverythingKept(twelve + "l", for: request))
}

@Test func keptReplyStopsPastTwelveHundredCharacters() {
    for keep in ["line", "block"] {
        let request = CompletionRequest(id: "c", kind: "editor", language: "ruby", before: "x", after: "", keep: keep)
        #expect(!AppleFMClient.hasEverythingKept(String(repeating: "x", count: 1_200), for: request))
        #expect(AppleFMClient.hasEverythingKept(String(repeating: "x", count: 1_201), for: request))
    }
}
