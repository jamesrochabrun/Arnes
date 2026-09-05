import XCTest
@testable import ArnesKit
import OpenRouterSwift

/// T5: `view_image` — the vision-gated `AttachingTool` — and the `CapabilityGatedTool` seam it
/// and `think` ride: what a model is offered, what a stale call gets, how an image reaches each
/// dialect's wire.
final class ImageToolsTests: XCTestCase {
  private func tempRecordStore() -> RunRecordStore {
    RunRecordStore(url: FileManager.default.temporaryDirectory
      .appendingPathComponent("arnes-image-runs-\(UUID().uuidString).jsonl"))
  }

  private func tempDialectStore() -> DialectVerdictStore {
    DialectVerdictStore(url: FileManager.default.temporaryDirectory
      .appendingPathComponent("arnes-image-verdicts-\(UUID().uuidString).jsonl"))
  }

  private func tempDir() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("arnes-image-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }
  // MARK: Fixtures — minimal headers the sniffer reads; nothing is ever decoded.

  /// A PNG signature + IHDR chunk announcing `width`×`height` (CRC not checked by anyone).
  static func png(width: Int, height: Int, padding: Int = 0) -> Data {
    var bytes: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 13]
    bytes += Array("IHDR".utf8)
    for value in [width, height] {
      bytes += [UInt8((value >> 24) & 0xFF), UInt8((value >> 16) & 0xFF), UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)]
    }
    bytes += [8, 6, 0, 0, 0, 0, 0, 0, 0]
    bytes += [UInt8](repeating: 0x41, count: padding)
    return Data(bytes)
  }

  /// A JPEG with an APP0 segment then a baseline SOF0 announcing `width`×`height`.
  static func jpeg(width: Int, height: Int) -> Data {
    var bytes: [UInt8] = [0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10]
    bytes += Array("JFIF".utf8) + [0x00, 0x01, 0x01, 0x00, 0x00, 0x01, 0x00, 0x01, 0x00, 0x00]
    bytes += [0xFF, 0xC0, 0x00, 0x11, 0x08, UInt8(height >> 8), UInt8(height & 0xFF), UInt8(width >> 8), UInt8(width & 0xFF), 0x03]
    bytes += [UInt8](repeating: 0x01, count: 16)
    return Data(bytes)
  }

  /// A JPEG made of no NUL byte at all: a comment segment, then end-of-image. `read_file`'s NUL
  /// sniff calls this text; the image sniffer must not.
  static let nulFreeJPEG: Data = {
    var bytes: [UInt8] = [0xFF, 0xD8, 0xFF, 0xFE, 0x01, 0x01]
    bytes += [UInt8](repeating: 0x78, count: 255)
    bytes += [0xFF, 0xD9]
    return Data(bytes)
  }()

  static func gif(width: Int, height: Int) -> Data {
    var bytes = Array("GIF89a".utf8)
    bytes += [UInt8(width & 0xFF), UInt8(width >> 8), UInt8(height & 0xFF), UInt8(height >> 8), 0, 0, 0, 0x3B]
    return Data(bytes)
  }

  static let webp = Data(Array("RIFF".utf8) + [0x10, 0, 0, 0] + Array("WEBP".utf8) + Array("VP8 ".utf8) + [0, 0, 0, 0])

  // MARK: Sniffing

  func testSniffsFormatsAndDimensions() {
    XCTAssertEqual(ImageSniff.mediaType(of: Self.png(width: 800, height: 600)), "image/png")
    XCTAssertEqual(ImageSniff.dimensions(of: Self.png(width: 800, height: 600), mediaType: "image/png").map { [$0.width, $0.height] }, [800, 600])
    XCTAssertEqual(ImageSniff.mediaType(of: Self.jpeg(width: 200, height: 100)), "image/jpeg")
    XCTAssertEqual(ImageSniff.dimensions(of: Self.jpeg(width: 200, height: 100), mediaType: "image/jpeg").map { [$0.width, $0.height] }, [200, 100])
    XCTAssertEqual(ImageSniff.mediaType(of: Self.gif(width: 320, height: 240)), "image/gif")
    XCTAssertEqual(ImageSniff.dimensions(of: Self.gif(width: 320, height: 240), mediaType: "image/gif").map { [$0.width, $0.height] }, [320, 240])
    XCTAssertEqual(ImageSniff.mediaType(of: Self.webp), "image/webp")
    XCTAssertNil(ImageSniff.dimensions(of: Self.webp, mediaType: "image/webp"))
    // The magic decides, not a NUL byte: a valid JPEG can have none in its first KB.
    XCTAssertEqual(ImageSniff.mediaType(of: Self.nulFreeJPEG), "image/jpeg")
    XCTAssertNil(ReadFileTool.binaryKind(of: Self.nulFreeJPEG), "read_file's sniff would call this text")
    XCTAssertNil(ImageSniff.mediaType(of: Data("hello".utf8)))
    XCTAssertNil(ImageSniff.mediaType(of: Data([0x25, 0x50, 0x44, 0x46, 0x2D, 0x31, 0x2E, 0x34, 0x00])), "a PDF is not an image")
  }

  func testDataURLRoundTrips() {
    let url = DataURL.make(mediaType: "image/png", base64: "QUJD")
    XCTAssertEqual(url, "data:image/png;base64,QUJD")
    let parsed = DataURL.parse(url)
    XCTAssertEqual(parsed?.mediaType, "image/png")
    XCTAssertEqual(parsed?.base64, "QUJD")
    XCTAssertNil(DataURL.parse("https://example.com/a.png"))
    XCTAssertNil(DataURL.parse("data:text/plain,hello"), "not base64: not an image payload")
  }

  // MARK: The tool

  func testRejectsNonImagesAndOversizedFiles() async throws {
    let root = try tempDir()
    defer { try? FileManager.default.removeItem(at: root) }
    try Data("not really".utf8).write(to: root.appendingPathComponent("fake.png"))
    try Data([0x25, 0x50, 0x44, 0x46, 0x2D, 0x31, 0x00, 0x00]).write(to: root.appendingPathComponent("doc.pdf"))
    try Self.png(width: 4000, height: 4000, padding: ViewImageTool.maxImageBytes).write(to: root.appendingPathComponent("huge.png"))
    let tool = ViewImageTool(root: root)

    let fake = try await tool.execute(arguments: ["path": .string("fake.png")])
    XCTAssertTrue(fake.hasPrefix("error:"), fake)
    XCTAssertTrue(fake.contains("not an image"), fake)
    XCTAssertTrue(fake.contains("looks like text"), fake)
    let pdf = try await tool.execute(arguments: ["path": .string("doc.pdf")])
    XCTAssertTrue(pdf.contains("looks like PDF"), pdf)
    let huge = try await tool.execute(arguments: ["path": .string("huge.png")])
    XCTAssertTrue(huge.hasPrefix("error: image is 5.0 MB"), huge)
    XCTAssertTrue(huge.contains("downscale it first"), huge)
    XCTAssertTrue(huge.contains("sips -Z 1600"), huge)
    // A missing file names the trap: a retyped path can differ by invisible characters
    // (macOS screenshot names carry U+202F), so the error coaches globbing the directory.
    let missing = try await tool.execute(arguments: ["path": .string("nope.png")])
    XCTAssertTrue(missing.hasPrefix("error: no file at"), missing)
    XCTAssertTrue(missing.contains("invisible characters"), missing)
    // Nothing queued for any of those: a failed call attaches nothing.
    let none = await tool.takeAttachment(callId: "c1")
    XCTAssertNil(none)
  }

  func testReturnsTheSentinelAndQueuesTheAttachment() async throws {
    let root = try tempDir()
    defer { try? FileManager.default.removeItem(at: root) }
    let image = Self.png(width: 800, height: 600, padding: 2000)
    try image.write(to: root.appendingPathComponent("shot.png"))
    let tool = ViewImageTool(root: root)

    let result = try await tool.execute(arguments: ["path": .string("shot.png")])
    XCTAssertEqual(result, "[image attached: \(root.appendingPathComponent("shot.png").path) (800x600, 2 KB)]")
    let taken = await tool.takeAttachment(callId: "c1")
    let attachment = try XCTUnwrap(taken)
    XCTAssertEqual(attachment.parts.count, 2)
    guard case .text(let caption, _) = attachment.parts[0] else { return XCTFail("a caption first") }
    XCTAssertTrue(caption.hasPrefix("Image from view_image "), caption)
    guard case .imageURL(let url, _, _) = attachment.parts[1] else { return XCTFail("then the image") }
    XCTAssertEqual(url, DataURL.make(mediaType: "image/png", base64: image.base64EncodedString()))
    // Taken once.
    let again = await tool.takeAttachment(callId: "c1")
    XCTAssertNil(again)
    // A NUL-free JPEG attaches too (no dimensions in its header: size only).
    try Self.nulFreeJPEG.write(to: root.appendingPathComponent("plain.jpg"))
    let plain = try await tool.execute(arguments: ["path": .string("plain.jpg")])
    XCTAssertEqual(plain, "[image attached: \(root.appendingPathComponent("plain.jpg").path) (1 KB)]")
    let plainAttachment = await tool.takeAttachment(callId: "c2")
    XCTAssertNotNil(plainAttachment)
  }

  /// Two sessions share one tool instance (the task tool hands the lead's tools to every
  /// nested session): each takes the image *it* read, whatever the interleaving.
  func testAttachmentsAreKeyedByTheExecutingTask() async throws {
    let root = try tempDir()
    defer { try? FileManager.default.removeItem(at: root) }
    let a = Self.png(width: 1, height: 1)
    let b = Self.gif(width: 2, height: 2)
    try a.write(to: root.appendingPathComponent("a.png"))
    try b.write(to: root.appendingPathComponent("b.gif"))
    let tool = ViewImageTool(root: root)
    let latch = Latch()

    // Task A executes, then waits for B to execute *and take* before it takes its own.
    let taskA = Task<String?, Never> {
      _ = try? await tool.execute(arguments: ["path": .string("a.png")])
      await latch.arrive()
      await latch.wait(for: 2)
      guard case .imageURL(let url, _, _)? = await tool.takeAttachment(callId: "a")?.parts.last else { return nil }
      return url
    }
    let taskB = Task<String?, Never> {
      await latch.wait(for: 1)
      _ = try? await tool.execute(arguments: ["path": .string("b.gif")])
      let taken = await tool.takeAttachment(callId: "b")
      await latch.arrive()
      guard case .imageURL(let url, _, _)? = taken?.parts.last else { return nil }
      return url
    }
    let (urlA, urlB) = await (taskA.value, taskB.value)
    XCTAssertEqual(urlA, DataURL.make(mediaType: "image/png", base64: a.base64EncodedString()))
    XCTAssertEqual(urlB, DataURL.make(mediaType: "image/gif", base64: b.base64EncodedString()))
  }

  func testGatedLikeReadFile() throws {
    let root = try tempDir()
    defer { try? FileManager.default.removeItem(at: root) }
    let tool = ViewImageTool(root: root)
    XCTAssertEqual(tool.permission, .readOnly)
    XCTAssertEqual(tool.permission(for: ["path": .string("shot.png")]), .readOnly)
    XCTAssertEqual(tool.permission(for: ["path": .string("/etc/hosts")]), .sensitive, "outside the tree: the read_file gate")
    XCTAssertEqual(
      tool.permission(for: ["path": .string(NSHomeDirectory() + "/.ssh/id_rsa.png")]), .sensitive)
    XCTAssertTrue(tool.summary(arguments: ["path": .string("/etc/hosts")]).contains("outside the working directory"))
    XCTAssertEqual(ViewImageTool.toolName, "view_image")
    XCTAssertTrue(ToolFilter.harnessToolNames.contains("view_image"))
    XCTAssertTrue(AutoApprovePermissions.pathGatedTools.contains("view_image"), "an unattended run never approves an out-of-tree image read")
  }

  func testAvailableOnlyForVisionModels() throws {
    let tool = ViewImageTool()
    let vision = try JSONDecoder().decode(OpenRouterModel.self, from: Data(Fixtures.visionManifestModel(id: "v").utf8))
    let text = try JSONDecoder().decode(OpenRouterModel.self, from: Data(Fixtures.manifestModel(id: "t").utf8))
    XCTAssertTrue(tool.isAvailable(for: ModelProfile(model: vision), configuration: .init()))
    XCTAssertFalse(tool.isAvailable(for: ModelProfile(model: text), configuration: .init()))
    XCTAssertFalse(tool.isAvailable(for: ModelProfile(unknownModelId: "openrouter/auto"), configuration: .init()))
  }

  // MARK: The seam in a session

  func testTextOnlyModelIsNeverOfferedViewImageAndAStaleCallIsCoached() async throws {
    let root = try tempDir()
    defer { try? FileManager.default.removeItem(at: root) }
    try Self.png(width: 8, height: 8).write(to: root.appendingPathComponent("shot.png"))
    let mock = MockOpenRouterService()
    mock.manifestJSON = Fixtures.manifest(Fixtures.manifestModel(id: "test/model"))
    mock.chunkScripts = [
      [Fixtures.toolCallChunk(id: "c1", name: "view_image", arguments: #"{"path":"shot.png"}"#), Fixtures.usageChunk(cost: 0.01)],
      [Fixtures.textChunk("ok"), Fixtures.usageChunk(cost: 0.01)],
    ]
    let session = Session(
      service: mock, tools: [ViewImageTool(root: root), SpyTool()], store: tempRecordStore(),
      configuration: .init(model: "test/model"))
    _ = try await Events.drain(await session.send("look"))

    // The toolset has it; the request to a text model does not, and neither does the next one.
    let definitions = await session.toolDefinitions.map(\.function.name)
    XCTAssertEqual(definitions, ["view_image", "spy"])
    XCTAssertEqual(mock.requests[0].tools?.map(\.function.name), ["spy"])
    XCTAssertEqual(mock.requests[1].tools?.map(\.function.name), ["spy"])
    // The hallucinated call is answered, not run: no image part anywhere in the next request.
    let toolMessage = try XCTUnwrap(mock.requests[1].messages.last { $0.role == .tool })
    XCTAssertEqual(toolMessage.content?.plainText, "error: view_image is not available for the current model. Available: spy")
    XCTAssertFalse(mock.requests[1].messages.contains { message in
      if case .parts? = message.content { return true } else { return false }
    })
    let maybeRecord = await session.lastRecord
    let record = try XCTUnwrap(maybeRecord)
    XCTAssertEqual(record.toolStats?["view_image"], ToolStat(calls: 1, errors: 1))
  }

  func testVisionModelGetsTheToolAndTheImageRidesAUserMessageAfterTheResults() async throws {
    let root = try tempDir()
    defer { try? FileManager.default.removeItem(at: root) }
    let image = Self.png(width: 8, height: 8)
    try image.write(to: root.appendingPathComponent("shot.png"))
    let mock = MockOpenRouterService()
    mock.manifestJSON = Fixtures.manifest(Fixtures.visionManifestModel(id: "acme/vision"))
    mock.chunkScripts = [
      [
        Fixtures.toolCallChunk(id: "c1", name: "view_image", arguments: #"{"path":"shot.png"}"#, index: 0),
        Fixtures.toolCallChunk(id: "c2", name: "spy", arguments: "{}", index: 1),
        Fixtures.usageChunk(cost: 0.01),
      ],
      [Fixtures.textChunk("a small square"), Fixtures.usageChunk(cost: 0.01)],
    ]
    let session = Session(
      service: mock, tools: [ViewImageTool(root: root), SpyTool()], store: tempRecordStore(),
      configuration: .init(model: "acme/vision"))
    _ = try await Events.drain(await session.send("look at shot.png"))

    XCTAssertEqual(mock.requests[0].tools?.map(\.function.name), ["view_image", "spy"])
    let messages = mock.requests[1].messages
    // system, user, assistant(2 calls), tool c1, tool c2, then the attachment as a user message.
    XCTAssertEqual(messages.map(\.role), [.system, .user, .assistant, .tool, .tool, .user])
    XCTAssertEqual(messages[3].toolCallId, "c1")
    XCTAssertEqual(messages[3].content?.plainText, "[image attached: \(root.appendingPathComponent("shot.png").path) (8x8, 1 KB)]")
    guard case .parts(let parts)? = messages[5].content else { return XCTFail("the image rides content parts") }
    XCTAssertEqual(parts.count, 2)
    guard case .imageURL(let url, _, _) = parts[1] else { return XCTFail("an image part") }
    XCTAssertEqual(url, DataURL.make(mediaType: "image/png", base64: image.base64EncodedString()))
    // The live history holds the same message (before the model's final reply), and the record
    // counts the call as a success.
    let history = await session.history
    XCTAssertEqual(history.map(\.role), [.user, .assistant, .tool, .tool, .user, .assistant])
    guard case .parts? = history[4].content else { return XCTFail("the attachment is in history") }
    let maybeRecord = await session.lastRecord
    let record = try XCTUnwrap(maybeRecord)
    XCTAssertEqual(record.toolStats?["view_image"], ToolStat(calls: 1, errors: 0))
    XCTAssertTrue(record.finished)
  }

  func testMessagesAndResponsesTranslatorsEncodeTheImagePart() throws {
    let attachment = Message(role: .user, content: .parts([
      .text("Image from view_image shot.png:"),
      .imageURL(url: DataURL.make(mediaType: "image/png", base64: "QUJD")),
    ]))
    // Anthropic: a text block and a base64 image block.
    let anthropic = Fixtures.jsonValue(MessagesTranslator.history([.user("hi"), attachment]))
    let blocks = anthropic.arrayValue?[1]["content"]?.arrayValue ?? []
    XCTAssertEqual(blocks.count, 2)
    XCTAssertEqual(blocks[0]["type"]?.stringValue, "text")
    XCTAssertEqual(blocks[1]["type"]?.stringValue, "image")
    XCTAssertEqual(blocks[1]["source"]?["type"]?.stringValue, "base64")
    XCTAssertEqual(blocks[1]["source"]?["media_type"]?.stringValue, "image/png")
    XCTAssertEqual(blocks[1]["source"]?["data"]?.stringValue, "QUJD")
    XCTAssertEqual(anthropic.arrayValue?[0]["content"]?.stringValue, "hi", "a plain user message is untouched")
    // After tool results the attachment joins their user message rather than opening another.
    let afterTools = Fixtures.jsonValue(MessagesTranslator.history([
      .user("look"),
      Message(role: .assistant, toolCalls: [ToolCall(id: "c1", type: "function", function: .init(name: "view_image", arguments: "{}"))]),
      .tool("[image attached: a.png (1 KB)]", toolCallId: "c1"),
      attachment,
    ]))
    XCTAssertEqual(afterTools.arrayValue?.count, 3)
    XCTAssertEqual(
      afterTools.arrayValue?[2]["content"]?.arrayValue?.map { $0["type"]?.stringValue }, ["tool_result", "text", "image"])
    // A remote image URL (not this tool's shape, but a valid part) stays a URL block.
    let remote = Fixtures.jsonValue(MessagesTranslator.userMessage(
      Message(role: .user, content: .parts([.imageURL(url: "https://example.com/a.png")]))))
    XCTAssertEqual(remote["content"]?.arrayValue?.first?["source"]?["type"]?.stringValue, "url")
    // Responses: input_text + input_image with the data URL as it is.
    let responses = Fixtures.jsonValue(ResponsesTranslator.history([.user("hi"), attachment]))
    let item = responses.arrayValue?[1]
    XCTAssertEqual(item?["type"]?.stringValue, "message")
    XCTAssertEqual(item?["role"]?.stringValue, "user")
    let parts = item?["content"]?.arrayValue ?? []
    XCTAssertEqual(parts.count, 2)
    XCTAssertEqual(parts[0]["type"]?.stringValue, "input_text")
    XCTAssertEqual(parts[1]["type"]?.stringValue, "input_image")
    XCTAssertEqual(parts[1]["image_url"]?.stringValue, "data:image/png;base64,QUJD")
    XCTAssertEqual(responses.arrayValue?[0]["content"]?.stringValue, "hi")
  }

  func testMessagesDialectSessionCarriesTheImageBlock() async throws {
    let root = try tempDir()
    defer { try? FileManager.default.removeItem(at: root) }
    let image = Self.png(width: 8, height: 8)
    try image.write(to: root.appendingPathComponent("shot.png"))
    let mock = MockOpenRouterService()
    mock.manifestJSON = Fixtures.manifest(Fixtures.visionManifestModel(id: "anthropic/claude-vision"))
    mock.messagesEventScripts = [
      [
        Fixtures.messagesEvent(#"{"type":"message_start","message":{"model":"anthropic/claude-vision","usage":{"input_tokens":10}}}"#),
        Fixtures.messagesEvent(#"{"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"tu_1","name":"view_image"}}"#),
        Fixtures.messagesEvent(#"{"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"{\"path\":\"shot.png\"}"}}"#),
        Fixtures.messagesEvent(#"{"type":"message_delta","delta":{"stop_reason":"tool_use"},"usage":{"cost":0.01}}"#),
      ],
      [
        Fixtures.messagesEvent(#"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"a square"}}"#),
        Fixtures.messagesEvent(#"{"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"cost":0.01}}"#),
      ],
    ]
    let session = Session(
      service: mock, tools: [ViewImageTool(root: root)], store: tempRecordStore(),
      dialectStore: tempDialectStore(), configuration: .init(model: "anthropic/claude-vision"))
    _ = try await Events.drain(await session.send("look"))

    XCTAssertEqual(mock.messagesRequests.count, 2)
    let second = Fixtures.jsonValue(mock.messagesRequests[1].messages).arrayValue ?? []
    // user, assistant(tool_use), then ONE user message: the tool_result block followed by the
    // attachment's text and image blocks — the canonical shape, never two consecutive user turns.
    XCTAssertEqual(second.count, 3)
    XCTAssertEqual(second[2]["role"]?.stringValue, "user")
    let blocks = second[2]["content"]?.arrayValue ?? []
    XCTAssertEqual(blocks.map { $0["type"]?.stringValue }, ["tool_result", "text", "image"])
    XCTAssertEqual(blocks[0]["tool_use_id"]?.stringValue, "tu_1")
    XCTAssertEqual(blocks.last?["source"]?["media_type"]?.stringValue, "image/png")
    XCTAssertEqual(blocks.last?["source"]?["data"]?.stringValue, image.base64EncodedString())
    let maybeRecord = await session.lastRecord
    let record = try XCTUnwrap(maybeRecord)
    XCTAssertEqual(record.dialect, "messages")
    XCTAssertTrue(record.finished)
  }

  /// The bound on a queue keyed by task identity: calls that executed but were never committed
  /// (an interrupt between the two) cannot pile up for the process's lifetime.
  func testPendingAttachmentsAreBoundedAcrossTasks() async throws {
    let root = try tempDir()
    defer { try? FileManager.default.removeItem(at: root) }
    try Self.png(width: 1, height: 1).write(to: root.appendingPathComponent("a.png"))
    let tool = ViewImageTool(root: root)
    // Each task executes and abandons its attachment; the tasks run one after another so every
    // one has its own identity for the duration of its call.
    for _ in 0..<(ViewImageTool.maxPendingTotal + 5) {
      let task = Task { _ = try? await tool.execute(arguments: ["path": .string("a.png")]) }
      _ = await task.value
    }
    XCTAssertLessThanOrEqual(tool.pendingAttachmentCount, ViewImageTool.maxPendingTotal)
    XCTAssertGreaterThan(tool.pendingAttachmentCount, 0)
  }

  // MARK: Images and a model without vision

  func testStrippingImagesKeepsTheCaptionAndDropsTheBytes() {
    let attachment = Message(role: .user, content: .parts([
      .text("Image from view_image shot.png:"),
      .imageURL(url: DataURL.make(mediaType: "image/png", base64: "QUJD")),
    ]))
    let textOnlyParts = Message(role: .user, content: .parts([.text("a"), .text("b")]))
    let plain = Message(role: .assistant, content: .text("hello"), toolCallId: nil, toolCalls: nil)
    let imageOnly = Message(role: .user, content: .parts([.imageURL(url: "data:image/png;base64,QUJD")]))
    let stripped = ViewImageTool.strippingImages(from: [.user("hi"), attachment, textOnlyParts, plain, imageOnly])
    XCTAssertEqual(stripped.map(\.role), [.user, .user, .user, .assistant, .user])
    guard case .text(let caption)? = stripped[1].content else { return XCTFail("the attachment becomes text") }
    XCTAssertEqual(caption, "Image from view_image shot.png:")
    guard case .parts(let kept)? = stripped[2].content else { return XCTFail("parts without an image are untouched") }
    XCTAssertEqual(kept.count, 2)
    XCTAssertEqual(stripped[3].content?.plainText, "hello")
    XCTAssertEqual(stripped[4].content?.plainText, "[image omitted — the current model does not take images]")
    XCTAssertFalse(stripped.contains { message in
      if case .parts(let parts)? = message.content {
        return parts.contains { if case .imageURL = $0 { return true } else { return false } }
      }
      return false
    })
  }

  /// The review's repro: an image attached under a vision model, then `/model` onto a text
  /// model — the image part must not ride the next request (the whole request would fail), while
  /// the caption and the sentinel keep the record of what was seen.
  func testModelSwapToATextModelStripsAnAttachedImageFromHistory() async throws {
    let root = try tempDir()
    defer { try? FileManager.default.removeItem(at: root) }
    let image = Self.png(width: 8, height: 8)
    try image.write(to: root.appendingPathComponent("shot.png"))
    let mock = MockOpenRouterService()
    mock.manifestJSON = Fixtures.manifest(
      Fixtures.visionManifestModel(id: "acme/vision"), Fixtures.manifestModel(id: "acme/text"))
    mock.chunkScripts = [
      [Fixtures.toolCallChunk(id: "c1", name: "view_image", arguments: #"{"path":"shot.png"}"#, model: "acme/vision"), Fixtures.usageChunk(cost: 0.01, model: "acme/vision")],
      [Fixtures.textChunk("a small square", model: "acme/vision"), Fixtures.usageChunk(cost: 0.01, model: "acme/vision")],
      [Fixtures.textChunk("still here", model: "acme/text"), Fixtures.usageChunk(cost: 0.01, model: "acme/text")],
    ]
    let session = Session(
      service: mock, tools: [ViewImageTool(root: root), SpyTool()], store: tempRecordStore(),
      configuration: .init(model: "acme/vision"))
    _ = try await Events.drain(await session.send("look at shot.png"))
    // The image rode the vision model's second request.
    XCTAssertTrue(mock.requests[1].messages.contains { if case .parts? = $0.content { return true } else { return false } })

    _ = try await session.setModel("acme/text")
    _ = try await Events.drain(await session.send("and now?"))
    let request = mock.requests[2]
    XCTAssertEqual(request.model, "acme/text")
    XCTAssertEqual(request.tools?.map(\.function.name), ["spy"])
    XCTAssertFalse(request.messages.contains { if case .parts? = $0.content { return true } else { return false } },
                   "no image part reaches a model without vision")
    // The attachment message is still there, as its caption; the sentinel result is untouched.
    XCTAssertEqual(request.messages.map(\.role), [.system, .user, .assistant, .tool, .user, .assistant, .user])
    XCTAssertEqual(request.messages[4].content?.plainText, "Image from view_image \(root.appendingPathComponent("shot.png").path):")
    XCTAssertEqual(request.messages[3].content?.plainText, "[image attached: \(root.appendingPathComponent("shot.png").path) (8x8, 1 KB)]")
    let history = await session.history
    XCTAssertFalse(history.contains { if case .parts? = $0.content { return true } else { return false } })
    // Swapping to a vision model strips nothing more (there is nothing left to strip) and the
    // conversation stands.
    _ = try await session.setModel("acme/vision")
    let after = await session.history
    XCTAssertEqual(after.map(\.role), history.map(\.role))
  }

  /// A `fork` agent lands on the lead's history: onto a model without vision the lead's image
  /// parts become their text (the same rule as a swap); onto a vision model they stay.
  func testForkOntoATextModelStripsTheLeadsImagesAndAVisionForkKeepsThem() async throws {
    let attachment = Message(role: .user, content: .parts([
      .text("Image from view_image shot.png:"),
      .imageURL(url: DataURL.make(mediaType: "image/png", base64: "QUJD")),
    ]))
    let leadHistory: [Message] = [
      .user("look at shot.png"),
      Message(role: .assistant, content: nil, toolCallId: nil, toolCalls: [
        ToolCall(id: "c1", function: .init(name: "view_image", arguments: #"{"path":"shot.png"}"#)),
      ]),
      .tool("[image attached: shot.png (8x8, 1 KB)]", toolCallId: "c1"),
      attachment,
      Message(role: .assistant, content: .text("a small square"), toolCallId: nil, toolCalls: nil),
    ]
    func forkRequest(onto model: String) async throws -> ChatCompletionRequest {
      let mock = MockOpenRouterService()
      mock.manifestJSON = Fixtures.manifest(
        Fixtures.visionManifestModel(id: "acme/vision"), Fixtures.manifestModel(id: "acme/text"))
      mock.chunkScripts = [[Fixtures.textChunk("checked", model: model), Fixtures.usageChunk(cost: 0.01, model: model)]]
      let tool = TaskTool(
        agents: [.fork], service: mock, tools: [SpyTool()], store: tempRecordStore(),
        configuration: Session.Configuration(model: "acme/vision"))
      tool.parentModel = { "acme/vision" }
      tool.parentSessionId = "LEAD-0000"
      tool.parentHistory = { (leadHistory, nil) }
      let result = try await tool.execute(arguments: [
        "agent": .string("fork"), "task": .string("check"), "model": .string(model), "background": .bool(false),
      ])
      XCTAssertEqual(result, "checked")
      return try XCTUnwrap(mock.requests.first)
    }
    let text = try await forkRequest(onto: "acme/text")
    XCTAssertEqual(text.model, "acme/text")
    XCTAssertFalse(text.messages.contains { if case .parts? = $0.content { return true } else { return false } },
                   "a fork onto a model without vision carries no image part")
    XCTAssertEqual(text.messages[4].content?.plainText, "Image from view_image shot.png:", "the caption survives as text")
    let vision = try await forkRequest(onto: "acme/vision")
    XCTAssertEqual(vision.model, "acme/vision")
    guard case .parts(let parts)? = vision.messages[4].content else { return XCTFail("a vision fork keeps the image") }
    XCTAssertEqual(parts.count, 2)
  }

  func testModelSwapToATextModelDropsTheToolAndCoachesAStaleCall() async throws {
    let root = try tempDir()
    defer { try? FileManager.default.removeItem(at: root) }
    try Self.png(width: 8, height: 8).write(to: root.appendingPathComponent("shot.png"))
    let mock = MockOpenRouterService()
    mock.manifestJSON = Fixtures.manifest(
      Fixtures.visionManifestModel(id: "acme/vision"), Fixtures.manifestModel(id: "acme/text"))
    mock.chunkScripts = [
      [Fixtures.textChunk("hello", model: "acme/vision"), Fixtures.usageChunk(cost: 0.01, model: "acme/vision")],
      [Fixtures.toolCallChunk(id: "c1", name: "view_image", arguments: #"{"path":"shot.png"}"#, model: "acme/text"), Fixtures.usageChunk(cost: 0.01, model: "acme/text")],
      [Fixtures.textChunk("understood", model: "acme/text"), Fixtures.usageChunk(cost: 0.01, model: "acme/text")],
    ]
    let session = Session(
      service: mock, tools: [ViewImageTool(root: root), SpyTool()], store: tempRecordStore(),
      configuration: .init(model: "acme/vision"))
    _ = try await Events.drain(await session.send("hi"))
    XCTAssertEqual(mock.requests[0].tools?.map(\.function.name), ["view_image", "spy"])

    _ = try await session.setModel("acme/text")
    _ = try await Events.drain(await session.send("now look at shot.png"))
    // The request after the swap no longer offers the tool …
    XCTAssertEqual(mock.requests[1].tools?.map(\.function.name), ["spy"])
    // … and the call the model made anyway is answered with the coaching error, never run.
    let toolMessage = try XCTUnwrap(mock.requests[2].messages.last { $0.role == .tool })
    XCTAssertEqual(toolMessage.content?.plainText, "error: view_image is not available for the current model. Available: spy")
    XCTAssertFalse(mock.requests[2].messages.contains { if case .parts? = $0.content { return true } else { return false } })
  }

  // MARK: think omission

  func testThinkIsOmittedForANativelyReasoningModelOnlyUnderAdaptiveThink() async throws {
    func toolNames(effort: Reasoning.Effort?, adaptive: Bool, reasoningModel: Bool = true) async throws -> [String]? {
      let mock = MockOpenRouterService()
      mock.manifestJSON = Fixtures.manifest(
        reasoningModel ? Fixtures.reasoningManifestModel(id: "test/model") : Fixtures.manifestModel(id: "test/model"))
      mock.chunkScripts = [[Fixtures.textChunk("ok"), Fixtures.usageChunk(cost: 0.01)]]
      let session = Session(
        service: mock, tools: [ThinkTool(), SpyTool()], store: tempRecordStore(),
        configuration: .init(model: "test/model", reasoningEffort: effort, adaptiveThink: adaptive))
      _ = try await Events.drain(await session.send("hi"))
      return mock.requests[0].tools?.map(\.function.name)
    }
    // adaptiveThink off (`policies.adaptiveThink: false`): the tool is offered whatever the model and the dial.
    let offByDefault = try await toolNames(effort: .medium, adaptive: false)
    XCTAssertEqual(offByDefault, ["think", "spy"])
    // On: a reasoning model with the dial on is not offered it …
    let omitted = try await toolNames(effort: .medium, adaptive: true)
    XCTAssertEqual(omitted, ["spy"])
    // … while a text model, no dial, or the `none` dial (thinking off) keep it.
    let textModel = try await toolNames(effort: .medium, adaptive: true, reasoningModel: false)
    XCTAssertEqual(textModel, ["think", "spy"])
    let noDial = try await toolNames(effort: nil, adaptive: true)
    XCTAssertEqual(noDial, ["think", "spy"])
    let dialOff = try await toolNames(effort: Reasoning.Effort.none, adaptive: true)
    XCTAssertEqual(dialOff, ["think", "spy"])
    XCTAssertTrue(Session.defaultTools.contains { $0.name == "think" }, "the toolset keeps the tool; the gate is per request")
  }

  func testEffortOffBringsThinkBackOnTheNextRequest() async throws {
    let mock = MockOpenRouterService()
    mock.manifestJSON = Fixtures.manifest(Fixtures.reasoningManifestModel(id: "test/model"))
    mock.chunkScripts = [
      [Fixtures.textChunk("one"), Fixtures.usageChunk(cost: 0.01)],
      [Fixtures.textChunk("two"), Fixtures.usageChunk(cost: 0.01)],
    ]
    let session = Session(
      service: mock, tools: [ThinkTool(), SpyTool()], store: tempRecordStore(),
      configuration: .init(model: "test/model", reasoningEffort: .high, adaptiveThink: true))
    _ = try await Events.drain(await session.send("hi"))
    XCTAssertEqual(mock.requests[0].tools?.map(\.function.name), ["spy"])
    // The prompt's tool sections and the request agree, both through `availableTools`.
    await session.setReasoningEffort(nil)
    _ = try await Events.drain(await session.send("again"))
    XCTAssertEqual(mock.requests[1].tools?.map(\.function.name), ["think", "spy"], "the live dial, not the seed, decides")
  }
}
