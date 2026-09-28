import CoreGraphics
import Foundation
import FoundationModels
import ImageIO

/// An image for one request. AppleFM reads it during the call and keeps no copy. The caller owns capture, permission
/// and the image's lifetime.
public enum AppleFMImage: Sendable, Equatable {
    /// An image in memory, such as a window capture.
    case cgImage(CGImage)
    /// An image file, such as one a person selected.
    case file(URL)

    /// Width and height in pixels. A file is read only as far as its header. Nil when the file is missing, isn't an
    /// image or has no size.
    public var pixelSize: (width: Int, height: Int)? {
        switch self {
        case .cgImage(let image):
            return image.width > 0 && image.height > 0 ? (width: image.width, height: image.height) : nil
        case .file(let url):
            guard url.isFileURL,
                  let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  CGImageSourceGetType(source) != nil,
                  CGImageSourceGetCount(source) > 0,
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  let width = properties[kCGImagePropertyPixelWidth] as? Int,
                  let height = properties[kCGImagePropertyPixelHeight] as? Int,
                  width > 0, height > 0 else { return nil }
            return (width: width, height: height)
        }
    }
}

/// Whether the system model takes an image with the prompt. Check `modelAvailability` first: a model that isn't
/// ready can't answer either way.
public enum AppleFMImageSupport: String, Sendable, Equatable {
    case supported = "supported"
    /// Image input needs macOS 27 or later. Text generation still works on macOS 26.
    case requiresNewerOS = "image_requires_macos_27"
    /// The system model on this Mac doesn't accept images.
    case visionUnsupported = "vision_unsupported"
}

/// One image request to the helper. The caller writes the instructions and the prompt; the helper adds no wording
/// of its own. `context`, when present, follows the prompt after a blank line.
public struct ImageRequest: Codable, Sendable, Equatable {
    public let id: String
    /// Always "image". It tells the helper this isn't a completion request.
    public let kind: String
    /// Absolute path to the image file.
    public let image: String
    public let instructions: String
    public let prompt: String
    public let context: String?
    /// 1–2048. Absent, the reply stops after 1024 tokens.
    public let maxResponseTokens: Int?
    /// Greedy sampling when true. Otherwise the model's default sampling.
    public let greedy: Bool?

    public init(id: String, image: String, instructions: String, prompt: String, context: String? = nil, maxResponseTokens: Int? = nil, greedy: Bool? = nil) {
        self.id = id; self.kind = "image"; self.image = image; self.instructions = instructions; self.prompt = prompt; self.context = context; self.maxResponseTokens = maxResponseTokens; self.greedy = greedy
    }
}

/// The helper's answer to an image request. `text` is the model's reply as written; the caller shapes and validates it.
public struct ImageResult: Codable, Sendable, Equatable {
    public let id: String
    public let status: CompletionStatus
    public let text: String?
    public let reason: String?

    public init(id: String, status: CompletionStatus, text: String? = nil, reason: String? = nil) {
        self.id = id; self.status = status; self.text = text; self.reason = reason
    }
}

extension AppleFMClient {
    /// Instructions, prompt and context together, in UTF-16 units as JavaScript counts them.
    public static let maximumImageTextCharacters = 8_000
    public static let maximumImageBytes = 20 * 1_024 * 1_024
    public static let maximumImagePixels = 36_000_000
    public static let maximumImageResponseTokens = 2_048
    static let defaultImageResponseTokens = 1_024

    /// Query on any supported deployment version, like `modelAvailability`.
    public var imageSupport: AppleFMImageSupport {
        guard #available(macOS 27, *) else { return .requiresNewerOS }
        return SystemLanguageModel.default.capabilities.contains(.vision) ? .supported : .visionUnsupported
    }

    /// Generate text about one image in a fresh on-device session. Model availability, image support and whether the
    /// image can be read are all checked before the model is called, so macOS 26 gets
    /// `AppleFMError.imageUnsupported(.requiresNewerOS)` rather than a model error. The caller owns deadlines and
    /// validation. Throws CancellationError or a sanitized AppleFMError.
    @available(macOS 26.0, *)
    public func generate(
        instructions: String,
        prompt: String,
        image: AppleFMImage,
        options: GenerationOptions = GenerationOptions()
    ) async throws -> String {
        try await AppleFMGenerationRunner.run(
            availability: { self.modelAvailability },
            imageSupport: { self.imageSupport },
            image: image
        ) {
            guard #available(macOS 27.0, *) else { throw AppleFMError.imageUnsupported(.requiresNewerOS) }
            let session = LanguageModelSession(
                model: SystemLanguageModel.default,
                instructions: instructions
            )
            let response = try await session.respond(to: Self.imagePrompt(prompt, image: image), options: options)
            return response.content
        }
    }

    /// Generate a caller-owned schema about one image. The same checks, cancellation and failure semantics apply.
    @available(macOS 26.0, *)
    public func generate<Content: Generable>(
        instructions: String,
        prompt: String,
        image: AppleFMImage,
        generating type: Content.Type,
        options: GenerationOptions = GenerationOptions()
    ) async throws -> Content {
        try await AppleFMGenerationRunner.run(
            availability: { self.modelAvailability },
            imageSupport: { self.imageSupport },
            image: image
        ) {
            guard #available(macOS 27.0, *) else { throw AppleFMError.imageUnsupported(.requiresNewerOS) }
            let session = LanguageModelSession(
                model: SystemLanguageModel.default,
                instructions: instructions
            )
            let response = try await session.respond(
                to: Self.imagePrompt(prompt, image: image),
                generating: type,
                includeSchemaInPrompt: true,
                options: options
            )
            return response.content
        }
    }

    /// The caller's text, then the image. The framework scales and converts the image itself.
    @available(macOS 27.0, *)
    static func imagePrompt(_ text: String, image: AppleFMImage) -> Prompt {
        switch image {
        case .cgImage(let cgImage):
            return Prompt {
                text
                Attachment(cgImage)
            }
        case .file(let url):
            return Prompt {
                text
                Attachment(imageURL: url)
            }
        }
    }

    /// The helper's image request: check it, then run one fresh session. Every outcome is a result, never a throw.
    public func analyze(_ request: ImageRequest) async -> ImageResult {
        let url = URL(fileURLWithPath: request.image)
        if let problem = Self.problem(with: request) ?? Self.imageFileProblem(at: url) {
            return ImageResult(id: request.id, status: .error, reason: problem)
        }
        guard !Task.isCancelled else { return ImageResult(id: request.id, status: .cancelled) }
        guard #available(macOS 26, *) else {
            return ImageResult(id: request.id, status: .unavailable, reason: AppleFMAvailability.unsupportedOS.rawValue)
        }
        do {
            let text = try await generate(
                instructions: request.instructions,
                prompt: Self.imagePromptText(for: request),
                image: .file(url),
                options: Self.imageOptions(for: request)
            )
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return ImageResult(id: request.id, status: .empty)
            }
            return ImageResult(id: request.id, status: .ok, text: text)
        } catch is CancellationError {
            return ImageResult(id: request.id, status: .cancelled)
        } catch let error as AppleFMError {
            switch error {
            case .unavailable(let availability):
                return ImageResult(id: request.id, status: .unavailable, reason: availability.rawValue)
            case .imageUnsupported(let support):
                return ImageResult(id: request.id, status: .unavailable, reason: support.rawValue)
            case .unreadableImage:
                return ImageResult(id: request.id, status: .error, reason: "unreadable image")
            case .generationFailed:
                return ImageResult(id: request.id, status: .error, reason: "model request failed")
            }
        } catch {
            return ImageResult(id: request.id, status: .error, reason: "model request failed")
        }
    }

    /// What is wrong with the request itself, before the image file is read.
    static func problem(with request: ImageRequest) -> String? {
        guard request.kind == "image" else { return "kind must be image" }
        let blank = { (text: String) in text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard !blank(request.instructions), !blank(request.prompt) else { return "instructions and prompt are required" }
        let length = request.instructions.utf16.count + request.prompt.utf16.count + (request.context?.utf16.count ?? 0)
        guard length <= maximumImageTextCharacters else { return "text exceeds \(maximumImageTextCharacters) characters" }
        if let tokens = request.maxResponseTokens, !(1...maximumImageResponseTokens).contains(tokens) {
            return "maxResponseTokens must be 1–\(maximumImageResponseTokens)"
        }
        guard request.image.hasPrefix("/") else { return "image path must be absolute" }
        return nil
    }

    /// Reads the file's metadata and image header, never its pixels.
    static func imageFileProblem(at url: URL) -> String? {
        let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        return imageProblem(isRegularFile: values?.isRegularFile == true, bytes: values?.fileSize,
                            pixelSize: AppleFMImage.file(url).pixelSize)
    }

    static func imageProblem(isRegularFile: Bool, bytes: Int?, pixelSize: (width: Int, height: Int)?) -> String? {
        guard isRegularFile, let bytes else { return "image not found" }
        guard bytes <= maximumImageBytes else { return "image exceeds 20 MB" }
        guard let pixelSize else { return "unreadable image" }
        guard pixelSize.width * pixelSize.height <= maximumImagePixels else { return "image exceeds 36 megapixels" }
        return nil
    }

    static func imagePromptText(for request: ImageRequest) -> String {
        guard let context = request.context, !context.isEmpty else { return request.prompt }
        return request.prompt + "\n\n" + context
    }

    @available(macOS 26.0, *)
    static func imageOptions(for request: ImageRequest) -> GenerationOptions {
        GenerationOptions(
            samplingMode: request.greedy == true ? .greedy : nil,
            maximumResponseTokens: request.maxResponseTokens ?? defaultImageResponseTokens
        )
    }
}
