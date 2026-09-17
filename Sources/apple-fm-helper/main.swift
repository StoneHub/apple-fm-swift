import Foundation
import AppleFM

@main
struct AppleFMHelper {
    static func main() async {
        let input = FileHandle.standardInput.readDataToEndOfFile()
        let decoder = JSONDecoder()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let result: CompletionResult
        do {
            let request = try decoder.decode(CompletionRequest.self, from: input)
            result = await AppleFMClient().complete(request)
        } catch {
            result = CompletionResult(id: "", status: .error, reason: "malformed request")
        }
        if let output = try? encoder.encode(result) {
            FileHandle.standardOutput.write(output)
            FileHandle.standardOutput.write(Data([0x0a]))
        }
    }
}
