import Foundation
import AppleFM

/// Read `kind` and `id` first, so an image request never goes through completion decoding.
private struct RequestKind: Decodable {
    let id: String?
    let kind: String?
}

@main
struct AppleFMHelper {
    static func main() async {
        let input = FileHandle.standardInput.readDataToEndOfFile()
        let decoder = JSONDecoder()
        let probe = try? decoder.decode(RequestKind.self, from: input)
        if probe?.kind == "image" {
            let result: ImageResult
            do {
                let request = try decoder.decode(ImageRequest.self, from: input)
                result = await AppleFMClient().analyze(request)
            } catch {
                result = ImageResult(id: probe?.id ?? "", status: .error, reason: "malformed request")
            }
            write(result)
            return
        }
        let result: CompletionResult
        do {
            let request = try decoder.decode(CompletionRequest.self, from: input)
            result = await AppleFMClient().complete(request)
        } catch {
            result = CompletionResult(id: "", status: .error, reason: "malformed request")
        }
        write(result)
    }

    private static func write<Output: Encodable>(_ result: Output) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        if let output = try? encoder.encode(result) {
            FileHandle.standardOutput.write(output)
            FileHandle.standardOutput.write(Data([0x0a]))
        }
    }
}
