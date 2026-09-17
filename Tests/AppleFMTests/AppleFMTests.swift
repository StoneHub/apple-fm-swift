import Testing
import Foundation
@testable import AppleFM

@Test func requestRoundTrip() throws {
    let request = CompletionRequest(id: "fixture", kind: "terminal", language: "zsh", before: "git sta", after: "")
    let data = try JSONEncoder().encode(request)
    #expect(try JSONDecoder().decode(CompletionRequest.self, from: data) == request)
}

@Test func emptyRequestDoesNotInvokeModel() async {
    let result = await AppleFMClient().complete(CompletionRequest(id: "empty", kind: "editor", language: "swift", before: "", after: ""))
    #expect(result == CompletionResult(id: "empty", status: .empty))
}
