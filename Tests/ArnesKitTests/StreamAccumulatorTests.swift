import XCTest
@testable import ArnesKit

final class StreamAccumulatorTests: XCTestCase {
  func testTextDeltasAccumulateAndEmit() {
    var accumulator = StreamAccumulator()
    XCTAssertEqual(accumulator.ingest(Fixtures.textChunk("Hel")).text, "Hel")
    XCTAssertEqual(accumulator.ingest(Fixtures.textChunk("lo")).text, "lo")
    XCTAssertEqual(accumulator.text, "Hello")
  }

  func testToolCallArgumentsSplitAcrossChunks() {
    var accumulator = StreamAccumulator()
    _ = accumulator.ingest(Fixtures.toolCallChunk(id: "c1", name: "bash", arguments: "{\"com"))
    _ = accumulator.ingest(Fixtures.toolArgsChunk(index: 0, arguments: "mand\":\"ls"))
    _ = accumulator.ingest(Fixtures.toolArgsChunk(index: 0, arguments: "\"}"))
    let calls = accumulator.toolCalls
    XCTAssertEqual(calls.count, 1)
    XCTAssertEqual(calls[0].id, "c1")
    XCTAssertEqual(calls[0].function?.name, "bash")
    XCTAssertEqual(calls[0].function?.arguments, "{\"command\":\"ls\"}")
  }

  func testInterleavedParallelToolCalls() {
    var accumulator = StreamAccumulator()
    _ = accumulator.ingest(Fixtures.toolCallChunk(id: "c1", name: "read_file", arguments: "{\"path\":", index: 0))
    _ = accumulator.ingest(Fixtures.toolCallChunk(id: "c2", name: "bash", arguments: "{\"command\":", index: 1))
    _ = accumulator.ingest(Fixtures.toolArgsChunk(index: 0, arguments: "\"a.txt\"}"))
    _ = accumulator.ingest(Fixtures.toolArgsChunk(index: 1, arguments: "\"pwd\"}"))
    let calls = accumulator.toolCalls
    XCTAssertEqual(calls.count, 2)
    XCTAssertEqual(calls[0].function?.arguments, "{\"path\":\"a.txt\"}")
    XCTAssertEqual(calls[1].id, "c2")
    XCTAssertEqual(calls[1].function?.arguments, "{\"command\":\"pwd\"}")
  }

  func testUsageAndRoutingArriveOnFinalChunk() {
    var accumulator = StreamAccumulator()
    _ = accumulator.ingest(Fixtures.textChunk("hi", model: "served/model"))
    _ = accumulator.ingest(Fixtures.usageChunk(cost: 0.0123, model: "served/model", provider: "SomeProvider"))
    XCTAssertEqual(accumulator.usage?.cost, 0.0123)
    XCTAssertEqual(accumulator.routedModel, "served/model")
    XCTAssertEqual(accumulator.provider, "SomeProvider")
    XCTAssertEqual(accumulator.finishReason, "stop")
  }
}
