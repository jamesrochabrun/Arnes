import XCTest
@testable import ArnesKit

final class SubprocessEnvironmentTests: XCTestCase {

  func testProviderTokenIsAlwaysWithheld() {
    let env = SubprocessEnvironment.default
    let resolved = env.resolve(inheriting: ["OPENROUTER_API_KEY": "sk-secret", "PATH": "/usr/bin", "HOME": "/h"])
    XCTAssertNil(resolved["OPENROUTER_API_KEY"], "the key that pays for the run is never handed to a subprocess")
    XCTAssertEqual(resolved["PATH"], "/usr/bin")
    XCTAssertEqual(resolved["HOME"], "/h")
  }

  func testExtraRedactedKey() {
    // The CLI adds the active provider's apiKeyEnv (e.g. ANTHROPIC_API_KEY).
    let env = SubprocessEnvironment(redactedKeys: ["ANTHROPIC_API_KEY"])
    let resolved = env.resolve(inheriting: ["ANTHROPIC_API_KEY": "x", "OPENROUTER_API_KEY": "y", "FOO": "bar"])
    XCTAssertNil(resolved["ANTHROPIC_API_KEY"])
    XCTAssertNil(resolved["OPENROUTER_API_KEY"], "built-in token names stay redacted too")
    XCTAssertEqual(resolved["FOO"], "bar")
  }

  func testInheritCoreKeepsOnlyShellBasics() {
    let env = SubprocessEnvironment(policy: ShellEnvironmentPolicy(inherit: .core))
    let resolved = env.resolve(inheriting: [
      "PATH": "/bin", "HOME": "/h", "LANG": "en_US.UTF-8", "LC_ALL": "C",
      "AWS_SECRET_ACCESS_KEY": "z", "MY_APP_STATE": "1",
    ])
    XCTAssertEqual(resolved["PATH"], "/bin")
    XCTAssertEqual(resolved["HOME"], "/h")
    XCTAssertEqual(resolved["LANG"], "en_US.UTF-8")
    XCTAssertEqual(resolved["LC_ALL"], "C")
    XCTAssertNil(resolved["AWS_SECRET_ACCESS_KEY"])
    XCTAssertNil(resolved["MY_APP_STATE"])
  }

  func testInheritNoneStartsEmptyThenSet() {
    let env = SubprocessEnvironment(policy: ShellEnvironmentPolicy(inherit: .empty, set: ["FOO": "1", "REF": "${HOME}"]))
    let resolved = env.resolve(inheriting: ["HOME": "/home/me", "PATH": "/bin"])
    XCTAssertNil(resolved["PATH"])
    XCTAssertEqual(resolved["FOO"], "1")
    XCTAssertEqual(resolved["REF"], "/home/me", "set values expand ${NAME} from the parent")
  }

  func testExcludeGlobAndExcludeSecrets() {
    let env = SubprocessEnvironment(policy: ShellEnvironmentPolicy(exclude: ["AWS_*"], excludeSecrets: true))
    let resolved = env.resolve(inheriting: [
      "AWS_REGION": "us", "AWS_PROFILE": "p", "GITHUB_TOKEN": "t", "MY_PASSWORD": "p", "KEEP": "1",
    ])
    XCTAssertNil(resolved["AWS_REGION"])
    XCTAssertNil(resolved["AWS_PROFILE"])
    XCTAssertNil(resolved["GITHUB_TOKEN"], "excludeSecrets drops *TOKEN*")
    XCTAssertNil(resolved["MY_PASSWORD"], "excludeSecrets drops *PASSWORD*")
    XCTAssertEqual(resolved["KEEP"], "1")
  }

  func testIncludeOnlyIsAWhitelist() {
    let env = SubprocessEnvironment(policy: ShellEnvironmentPolicy(includeOnly: ["PATH", "CI"]))
    let resolved = env.resolve(inheriting: ["PATH": "/bin", "CI": "true", "SECRET": "x"])
    XCTAssertEqual(Set(resolved.keys), ["PATH", "CI"])
  }

  func testBashCannotEchoTheProviderKey() async {
    // End-to-end through the tool: even with the key in the process env, the command
    // launched by bash doesn't see it.
    setenv("OPENROUTER_API_KEY", "sk-live-do-not-leak", 1)
    defer { unsetenv("OPENROUTER_API_KEY") }
    let bash = BashTool()
    let output = try? await bash.execute(arguments: ["command": .string("echo key=[$OPENROUTER_API_KEY]")])
    XCTAssertNotNil(output)
    XCTAssertTrue(output?.contains("key=[]") == true, "the command saw an empty value, got: \(output ?? "nil")")
    XCTAssertFalse(output?.contains("sk-live-do-not-leak") == true)
  }
}
