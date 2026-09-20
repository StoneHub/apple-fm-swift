import AppleFM
import Foundation
import FoundationModels

@available(macOS 26.0, *)
@Generable
private struct EditedText {
    var text: String
}

/// Synthetic input only. Run explicitly; this is not part of the unit tests.
@main
struct NativeGenerationExample {
    @MainActor
    static func main() async {
        let client = AppleFMClient()
        print("availability: \(client.modelAvailability.rawValue)")
        guard #available(macOS 26.0, *), client.modelAvailability == .available else {
            print("On-device generation unavailable.")
            exit(1)
        }
        do {
            let output = try await client.generate(
                instructions: "Remove filler and add punctuation. Preserve the meaning. Return the edited sentence in text.",
                prompt: "um hello there we can meet tomorrow",
                generating: EditedText.self,
                options: GenerationOptions(sampling: .greedy, maximumResponseTokens: 100)
            )
            guard !output.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                print("Empty structured response.")
                exit(1)
            }
            print("structured response: \(output.text)")
        } catch is CancellationError {
            print("Generation cancelled.")
            exit(1)
        } catch {
            print("Generation failed.")
            exit(1)
        }
    }
}
