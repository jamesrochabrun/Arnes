import XCTest
@testable import ArnesKit
import OpenRouterSwift

final class MCPEnvironmentTests: XCTestCase {
  func testProviderTokensAreWithheldUnlessTheConfigPassesThemOn() {
    let parent = ["PATH": "/usr/bin", "OPENROUTER_API_KEY": "sk-or", "GATEWAY_TOKEN": "jwt", "HOME": "/Users/x"]
    let redacted: Set<String> = ["OPENROUTER_API_KEY", "GATEWAY_TOKEN"]

    let plain = ProcessMCPTransport.environment(
      for: MCPServerConfig(command: "npx"), inheriting: parent, redacting: redacted)
    XCTAssertEqual(plain, ["PATH": "/usr/bin", "HOME": "/Users/x"])

    let explicit = ProcessMCPTransport.environment(
      for: MCPServerConfig(command: "npx", env: ["GATEWAY_TOKEN": "${GATEWAY_TOKEN}", "DEBUG": "1", "MIXED": "a-${HOME}-b"]),
      inheriting: parent, redacting: redacted)
    XCTAssertEqual(explicit["GATEWAY_TOKEN"], "jwt", "an explicit ${VAR} passes a redacted variable through on purpose")
    XCTAssertNil(explicit["OPENROUTER_API_KEY"])
    XCTAssertEqual(explicit["DEBUG"], "1")
    XCTAssertEqual(explicit["MIXED"], "a-/Users/x-b")
    XCTAssertEqual(ProcessMCPTransport.expand("${MISSING}", from: parent), "")
    XCTAssertEqual(ProcessMCPTransport.expand("literal $HOME ${", from: parent), "literal $HOME ${")
  }
}

final class EvalCaptureReviewTests: XCTestCase {
  private let draft = #"{"id": "count-lines", "prompt": "write the line count of a.txt to n.txt", "setup": "printf 'x\ny\n' > a.txt", "check": "test \"$(cat n.txt)\" = 2"}"#

  func testReviewerSeesTheDraftBeforeItsScriptsRun() async throws {
    let mock = MockOpenRouterService()
    mock.chatResponses = [Fixtures.textResponse(draft)]
    let seen = Reviewed()
    let distiller = EvalTaskDistiller(service: mock) { task in
      await seen.record(task)
      return false
    }
    do {
      _ = try await distiller.distill(from: "source", model: "m")
      XCTFail("expected declined")
    } catch EvalCaptureError.declined {
      // expected
    }
    let tasks = await seen.tasks
    XCTAssertEqual(tasks.map(\.id), ["count-lines"])
    XCTAssertEqual(mock.requests.count, 1, "a decline ends the capture — no retry, no extra spend")
  }

  func testApprovingReviewerLetsValidationProceed() async throws {
    let mock = MockOpenRouterService()
    mock.chatResponses = [Fixtures.textResponse(draft)]
    let distiller = EvalTaskDistiller(service: mock) { _ in true }
    let output = try await distiller.distill(from: "source", model: "m")
    XCTAssertEqual(output.task.id, "count-lines")
  }

  private actor Reviewed {
    var tasks: [EvalTask] = []
    func record(_ task: EvalTask) { tasks.append(task) }
  }
}
