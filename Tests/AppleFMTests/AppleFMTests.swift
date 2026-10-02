import Testing
import CoreGraphics
import Foundation
import FoundationModels
import ImageIO
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

private func temporaryURL(_ suffix: String) -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("applefm-\(UUID().uuidString)\(suffix)")
}

private func blankImage(width: Int, height: Int) throws -> CGImage {
    let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                         space: CGColorSpaceCreateDeviceRGB(),
                                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    return try #require(context.makeImage())
}

private func writePNG(width: Int, height: Int) throws -> URL {
    let url = temporaryURL(".png")
    let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
    let image = try blankImage(width: width, height: height)
    CGImageDestinationAddImage(destination, image, nil)
    #expect(CGImageDestinationFinalize(destination))
    return url
}

private func writeText() throws -> URL {
    let url = temporaryURL(".png")
    try Data("not an image".utf8).write(to: url)
    return url
}

private func imageRequest(image: String = "/tmp/screen.png", instructions: String = "Answer briefly.", prompt: String = "What does the error say?",
                          context: String? = nil, maxResponseTokens: Int? = nil) -> ImageRequest {
    ImageRequest(id: "image", image: image, instructions: instructions, prompt: prompt, context: context, maxResponseTokens: maxResponseTokens)
}

@Test func imageRequestDecodesWithOptionalFieldsAbsent() throws {
    let json = #"{"id":"i","kind":"image","image":"/tmp/screen.png","instructions":"Answer briefly.","prompt":"What is shown?"}"#
    let request = try JSONDecoder().decode(ImageRequest.self, from: Data(json.utf8))
    #expect(request.kind == "image")
    #expect(request.context == nil && request.maxResponseTokens == nil && request.greedy == nil)
    let encoded = String(decoding: try JSONEncoder().encode(request), as: UTF8.self)
    #expect(!encoded.contains("context") && !encoded.contains("greedy"))
    #expect(try JSONDecoder().decode(ImageRequest.self, from: Data(encoded.utf8)) == request)
}

@Test func completionRequestsStillDecodeAndImageRequestsDoNot() throws {
    // The helper routes on kind, and a helper built before image support rejects an image request as malformed.
    let json = #"{"id":"i","kind":"image","image":"/tmp/screen.png","instructions":"Answer briefly.","prompt":"What is shown?"}"#
    #expect(throws: DecodingError.self) { try JSONDecoder().decode(CompletionRequest.self, from: Data(json.utf8)) }
}

@Test func imageRequestProblemsAreFoundBeforeTheFileIsRead() throws {
    #expect(AppleFMClient.problem(with: imageRequest()) == nil)
    let otherKind = #"{"id":"i","kind":"editor","image":"/tmp/screen.png","instructions":"Answer.","prompt":"What?"}"#
    #expect(AppleFMClient.problem(with: try JSONDecoder().decode(ImageRequest.self, from: Data(otherKind.utf8))) == "kind must be image")
    #expect(AppleFMClient.problem(with: imageRequest(instructions: " \n")) == "instructions and prompt are required")
    #expect(AppleFMClient.problem(with: imageRequest(prompt: "")) == "instructions and prompt are required")
    let limit = AppleFMClient.maximumImageTextCharacters
    let full = imageRequest(instructions: "i", prompt: "p", context: String(repeating: "x", count: limit - 2))
    #expect(AppleFMClient.problem(with: full) == nil)
    let over = imageRequest(instructions: "i", prompt: "p", context: String(repeating: "x", count: limit - 1))
    #expect(AppleFMClient.problem(with: over) == "text exceeds 8000 characters")
    for tokens in [1, AppleFMClient.maximumImageResponseTokens] {
        #expect(AppleFMClient.problem(with: imageRequest(maxResponseTokens: tokens)) == nil)
    }
    for tokens in [0, -1, AppleFMClient.maximumImageResponseTokens + 1] {
        #expect(AppleFMClient.problem(with: imageRequest(maxResponseTokens: tokens)) == "maxResponseTokens must be 1–2048")
    }
    #expect(AppleFMClient.problem(with: imageRequest(image: "screen.png")) == "image path must be absolute")
}

@Test func imageLimitsCoverSizeAndPixels() {
    let bytes = AppleFMClient.maximumImageBytes
    #expect(AppleFMClient.imageProblem(isRegularFile: false, bytes: 10, pixelSize: (width: 1, height: 1)) == "image not found")
    #expect(AppleFMClient.imageProblem(isRegularFile: true, bytes: nil, pixelSize: (width: 1, height: 1)) == "image not found")
    #expect(AppleFMClient.imageProblem(isRegularFile: true, bytes: bytes, pixelSize: (width: 1, height: 1)) == nil)
    #expect(AppleFMClient.imageProblem(isRegularFile: true, bytes: bytes + 1, pixelSize: (width: 1, height: 1)) == "image exceeds 20 MB")
    #expect(AppleFMClient.imageProblem(isRegularFile: true, bytes: 10, pixelSize: nil) == "unreadable image")
    #expect(AppleFMClient.imageProblem(isRegularFile: true, bytes: 10, pixelSize: (width: 6_000, height: 6_000)) == nil)
    #expect(AppleFMClient.imageProblem(isRegularFile: true, bytes: 10, pixelSize: (width: 6_001, height: 6_000)) == "image exceeds 36 megapixels")
}

@Test func pixelSizeReadsOnlyRealImages() throws {
    let png = try writePNG(width: 4, height: 3)
    let text = try writeText()
    defer { try? FileManager.default.removeItem(at: png); try? FileManager.default.removeItem(at: text) }
    let file = AppleFMImage.file(png).pixelSize
    #expect(file?.width == 4 && file?.height == 3)
    let memory = AppleFMImage.cgImage(try blankImage(width: 5, height: 2)).pixelSize
    #expect(memory?.width == 5 && memory?.height == 2)
    #expect(AppleFMImage.file(text).pixelSize == nil)
    #expect(AppleFMImage.file(temporaryURL(".png")).pixelSize == nil)
    #expect(AppleFMImage.file(try #require(URL(string: "https://example.com/a.png"))).pixelSize == nil)
}

@Test func imageFileProblemChecksTheFileItself() throws {
    let png = try writePNG(width: 4, height: 3)
    let text = try writeText()
    defer { try? FileManager.default.removeItem(at: png); try? FileManager.default.removeItem(at: text) }
    #expect(AppleFMClient.imageFileProblem(at: png) == nil)
    #expect(AppleFMClient.imageFileProblem(at: text) == "unreadable image")
    #expect(AppleFMClient.imageFileProblem(at: temporaryURL(".png")) == "image not found")
    #expect(AppleFMClient.imageFileProblem(at: FileManager.default.temporaryDirectory) == "image not found")
}

@Test func analyzeReportsBadRequestsWithoutTheModel() async throws {
    let text = try writeText()
    defer { try? FileManager.default.removeItem(at: text) }
    #expect(await AppleFMClient().analyze(imageRequest(image: "screen.png"))
            == ImageResult(id: "image", status: .error, reason: "image path must be absolute"))
    #expect(await AppleFMClient().analyze(imageRequest(image: text.path))
            == ImageResult(id: "image", status: .error, reason: "unreadable image"))
    #expect(await AppleFMClient().analyze(imageRequest(image: temporaryURL(".png").path))
            == ImageResult(id: "image", status: .error, reason: "image not found"))
}

@Test func imagePromptTextJoinsContextAfterABlankLine() {
    #expect(AppleFMClient.imagePromptText(for: imageRequest(prompt: "Explain.")) == "Explain.")
    #expect(AppleFMClient.imagePromptText(for: imageRequest(prompt: "Explain.", context: "")) == "Explain.")
    #expect(AppleFMClient.imagePromptText(for: imageRequest(prompt: "Explain.", context: "let x = 1")) == "Explain.\n\nlet x = 1")
}

@Test func imageOptionsUseModelSamplingUnlessGreedy() throws {
    guard #available(macOS 26.0, *) else { return }
    #expect(AppleFMClient.imageOptions(for: imageRequest()) == GenerationOptions(samplingMode: nil, maximumResponseTokens: 1_024))
    let greedy = ImageRequest(id: "g", image: "/tmp/a.png", instructions: "i", prompt: "p", maxResponseTokens: 300, greedy: true)
    #expect(AppleFMClient.imageOptions(for: greedy) == GenerationOptions(samplingMode: .greedy, maximumResponseTokens: 300))
}

@Test func imageSupportIsReadableOnEverySystem() {
    let support = AppleFMClient().imageSupport
    let answers: [AppleFMImageSupport] = [.supported, .requiresNewerOS, .visionUnsupported]
    #expect(answers.contains(support))
    if #unavailable(macOS 27) { #expect(support == .requiresNewerOS) }
    #expect(AppleFMImageSupport.requiresNewerOS.rawValue == "image_requires_macos_27")
    #expect(AppleFMImageSupport.visionUnsupported.rawValue == "vision_unsupported")
}

@Test func imageRunnerChecksModelThenSupportThenImage() async throws {
    let recorder = InvocationRecorder()
    let readable = AppleFMImage.cgImage(try blankImage(width: 2, height: 2))
    let missing = AppleFMImage.file(temporaryURL(".png"))
    let cases: [(AppleFMAvailability, AppleFMImageSupport, AppleFMImage, AppleFMError)] = [
        (.modelNotReady, .supported, readable, .unavailable(.modelNotReady)),
        (.available, .visionUnsupported, readable, .imageUnsupported(.visionUnsupported)),
        (.available, .requiresNewerOS, readable, .imageUnsupported(.requiresNewerOS)),
        (.available, .supported, missing, .unreadableImage)
    ]
    for (availability, support, image, expected) in cases {
        do {
            _ = try await AppleFMGenerationRunner.run(availability: { availability }, imageSupport: {
                if availability != .available { Issue.record("image support must not be read for an unavailable model") }
                return support
            }, image: image) {
                await recorder.recordInvocation()
                return "unexpected"
            }
            Issue.record("image request unexpectedly generated a response")
        } catch let error as AppleFMError {
            #expect(error == expected)
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }
    #expect(await recorder.count == 0)
    let output = try await AppleFMGenerationRunner.run(availability: { .available }, imageSupport: { .supported }, image: readable) {
        await recorder.recordInvocation()
        return "described"
    }
    #expect(output == "described")
    #expect(await recorder.count == 1)
}

@Test func imageRunnerHonorsCancellationBeforeChecks() async throws {
    let readable = AppleFMImage.cgImage(try blankImage(width: 2, height: 2))
    let task = Task {
        withUnsafeCurrentTask { $0?.cancel() }
        return try await AppleFMGenerationRunner.run(availability: { .available }, imageSupport: {
            Issue.record("image support must not be read after pre-cancellation")
            return .supported
        }, image: readable) { "unexpected" }
    }
    task.cancel()
    await #expect(throws: CancellationError.self) { try await task.value }
}

@Test func imageResultsEncodeOnlyWhatIsSet() throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let ok = String(decoding: try encoder.encode(ImageResult(id: "i", status: .ok, text: "A dialog.")), as: UTF8.self)
    #expect(ok == #"{"id":"i","status":"ok","text":"A dialog."}"#)
    let unavailable = String(decoding: try encoder.encode(ImageResult(id: "i", status: .unavailable, reason: "vision_unsupported")), as: UTF8.self)
    #expect(unavailable == #"{"id":"i","reason":"vision_unsupported","status":"unavailable"}"#)
}
