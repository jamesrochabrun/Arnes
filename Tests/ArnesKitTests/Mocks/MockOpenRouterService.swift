import Foundation
import OpenRouterSwift

// MARK: - Unimplemented defaults

/// Test-target defaults so mocks only implement the endpoints a test actually uses.
/// Anything else crashing loudly is the point.
extension OpenRouterService {
  func unimplemented(_ function: String = #function) -> Never {
    fatalError("MockOpenRouterService does not implement \(function)")
  }

  public func chatCompletion(_ request: ChatCompletionRequest) async throws -> ChatCompletionResponse { unimplemented() }
  public func chatCompletionStream(_ request: ChatCompletionRequest) async throws -> AsyncThrowingStream<ChatCompletionChunk, Error> { unimplemented() }
  public func message(_ request: MessagesRequest) async throws -> MessagesResponse { unimplemented() }
  public func messageStream(_ request: MessagesRequest) async throws -> AsyncThrowingStream<MessagesStreamEvent, Error> { unimplemented() }
  public func response(_ request: ResponsesRequest) async throws -> ResponsesResponse { unimplemented() }
  public func responseStream(_ request: ResponsesRequest) async throws -> AsyncThrowingStream<ResponsesStreamEvent, Error> { unimplemented() }
  public func embeddings(_ request: EmbeddingsRequest) async throws -> EmbeddingsResponse { unimplemented() }
  public func embeddingsModels() async throws -> [OpenRouterModel] { unimplemented() }
  public func rerank(_ request: RerankRequest) async throws -> RerankResponse { unimplemented() }
  public func presets(offset: Int?, limit: Int?) async throws -> PresetList { unimplemented() }
  public func preset(slug: String) async throws -> PresetDetail { unimplemented() }
  public func presetVersions(slug: String, offset: Int?, limit: Int?) async throws -> PresetVersionList { unimplemented() }
  public func presetVersion(slug: String, version: String) async throws -> PresetVersion { unimplemented() }
  public func savePreset(slug: String, fromChatCompletion request: ChatCompletionRequest) async throws -> PresetDetail { unimplemented() }
  public func savePreset(slug: String, fromMessages request: MessagesRequest) async throws -> PresetDetail { unimplemented() }
  public func savePreset(slug: String, fromResponses request: ResponsesRequest) async throws -> PresetDetail { unimplemented() }
  public func models(filter: ModelsFilter?) async throws -> [OpenRouterModel] { unimplemented() }
  public func model(author: String, slug: String) async throws -> OpenRouterModel { unimplemented() }
  public func modelEndpoints(author: String, slug: String) async throws -> ModelEndpointsList { unimplemented() }
  public func modelsCount() async throws -> Int { unimplemented() }
  public func userModels() async throws -> [OpenRouterModel] { unimplemented() }
  public func keyInfo() async throws -> KeyInfo { unimplemented() }
  public func credits() async throws -> Credits { unimplemented() }
  public func imageGeneration(_ request: ImageGenerationRequest) async throws -> ImageGenerationResponse { unimplemented() }
  public func imageGenerationStream(_ request: ImageGenerationRequest) async throws -> AsyncThrowingStream<ImageStreamEvent, Error> { unimplemented() }
  public func imagesModels() async throws -> [ImageModel] { unimplemented() }
  public func imageModelEndpoints(author: String, slug: String) async throws -> ImageModelEndpointsList { unimplemented() }
  public func videoGeneration(_ request: VideoGenerationRequest) async throws -> VideoJob { unimplemented() }
  public func video(jobId: String) async throws -> VideoJob { unimplemented() }
  public func videoContent(jobId: String, index: Int?) async throws -> Data { unimplemented() }
  public func videosModels() async throws -> [VideoModel] { unimplemented() }
  public func audioSpeech(_ request: AudioSpeechRequest) async throws -> Data { unimplemented() }
  public func audioTranscription(_ request: AudioTranscriptionRequest) async throws -> AudioTranscription { unimplemented() }
  public func audioTranscription(
    fileData: Data,
    filename: String,
    model: String,
    language: String?,
    responseFormat: AudioTranscriptionRequest.ResponseFormat?,
    temperature: Double?,
    timestampGranularities: [String]?)
    async throws -> AudioTranscription
  { unimplemented() }
  public func files(limit: Int?, cursor: String?) async throws -> FileList { unimplemented() }
  public func uploadFile(data: Data, filename: String, mimeType: String) async throws -> FileObject { unimplemented() }
  public func file(id: String) async throws -> FileObject { unimplemented() }
  public func deleteFile(id: String) async throws -> FileDeleted { unimplemented() }
  public func fileContent(id: String) async throws -> Data { unimplemented() }
  public func generation(id: String) async throws -> Generation { unimplemented() }
  public func generationContent(id: String) async throws -> GenerationContent { unimplemented() }
  public func submitGenerationFeedback(generationId: String, category: GenerationFeedbackCategory, comment: String?) async throws -> Bool { unimplemented() }
  public func activity(filter: ActivityFilter?) async throws -> [ActivityRow] { unimplemented() }
  public func analyticsMeta() async throws -> AnalyticsMeta { unimplemented() }
  public func analyticsQuery(_ request: AnalyticsQueryRequest) async throws -> AnalyticsQueryResult { unimplemented() }
  public func providers() async throws -> [Provider] { unimplemented() }
  public func zdrEndpoints() async throws -> [ZDREndpoint] { unimplemented() }
  public func benchmarks() async throws -> BenchmarksResponse { unimplemented() }
  public func taskClassifications() async throws -> TaskClassifications { unimplemented() }
  public func appRankings(category: String?, sort: String?, limit: Int?) async throws -> [AppRanking] { unimplemented() }
  public func rankingsDaily(startDate: String?, endDate: String?, category: String?) async throws -> [DailyRanking] { unimplemented() }
  public func sessionCosts(appSlug: String?, model: String?, limit: Int?) async throws -> [SessionCost] { unimplemented() }
}

// MARK: - MockOpenRouterService

enum MockError: Error {
  case scriptExhausted
}

/// Scriptable mock: streaming calls consume `chunkScripts` in order, non-streaming
/// calls consume `chatResponses`, and every chat request is recorded for inspection.
final class MockOpenRouterService: OpenRouterService, @unchecked Sendable {
  private let lock = NSLock()

  var chunkScripts: [[ChatCompletionChunk]] = []
  /// Per-model scripts, consulted before `chunkScripts` — required when concurrent
  /// callers (panel candidates) would otherwise race on the shared queue.
  var chunkScriptsByModel: [String: [[ChatCompletionChunk]]] = [:]
  var chatResponses: [ChatCompletionResponse] = []
  var manifestJSON = "[]"
  private var recordedRequests: [ChatCompletionRequest] = []

  var requests: [ChatCompletionRequest] {
    lock.lock()
    defer { lock.unlock() }
    return recordedRequests
  }

  func chatCompletion(_ request: ChatCompletionRequest) async throws -> ChatCompletionResponse {
    let response: ChatCompletionResponse? = lock.withLock {
      recordedRequests.append(request)
      return chatResponses.isEmpty ? nil : chatResponses.removeFirst()
    }
    guard let response else { throw MockError.scriptExhausted }
    return response
  }

  func chatCompletionStream(_ request: ChatCompletionRequest) async throws -> AsyncThrowingStream<ChatCompletionChunk, Error> {
    let script: [ChatCompletionChunk]? = lock.withLock {
      recordedRequests.append(request)
      if let model = request.model, var scripts = chunkScriptsByModel[model], !scripts.isEmpty {
        let first = scripts.removeFirst()
        chunkScriptsByModel[model] = scripts
        return first
      }
      return chunkScripts.isEmpty ? nil : chunkScripts.removeFirst()
    }
    guard let script else { throw MockError.scriptExhausted }
    return AsyncThrowingStream { continuation in
      for chunk in script {
        continuation.yield(chunk)
      }
      continuation.finish()
    }
  }

  func models(filter: ModelsFilter?) async throws -> [OpenRouterModel] {
    try JSONDecoder().decode([OpenRouterModel].self, from: Data(manifestJSON.utf8))
  }
}

// MARK: - Fixtures

enum Fixtures {
  /// Decodes a chunk from raw SSE-shaped JSON.
  static func chunk(_ json: String) -> ChatCompletionChunk {
    try! JSONDecoder().decode(ChatCompletionChunk.self, from: Data(json.utf8))
  }

  static func response(_ json: String) -> ChatCompletionResponse {
    try! JSONDecoder().decode(ChatCompletionResponse.self, from: Data(json.utf8))
  }

  static func textChunk(_ text: String, model: String = "test/model") -> ChatCompletionChunk {
    chunk("""
      {"model":"\(model)","choices":[{"index":0,"delta":{"content":\(encodeJSONString(text))}}]}
      """)
  }

  static func toolCallChunk(
    id: String,
    name: String,
    arguments: String,
    index: Int = 0,
    model: String = "test/model")
    -> ChatCompletionChunk
  {
    chunk("""
      {"model":"\(model)","choices":[{"index":0,"delta":{"tool_calls":[{"index":\(index),"id":"\(id)","type":"function","function":{"name":"\(name)","arguments":\(encodeJSONString(arguments))}}]}}]}
      """)
  }

  /// A fragment that only appends to an existing call's arguments.
  static func toolArgsChunk(index: Int, arguments: String) -> ChatCompletionChunk {
    chunk("""
      {"choices":[{"index":0,"delta":{"tool_calls":[{"index":\(index),"function":{"arguments":\(encodeJSONString(arguments))}}]}}]}
      """)
  }

  static func usageChunk(
    cost: Double,
    model: String = "test/model",
    provider: String? = nil,
    promptTokens: Int = 10)
    -> ChatCompletionChunk
  {
    let providerField = provider.map { ",\"provider\":\"\($0)\"" } ?? ""
    return chunk("""
      {"model":"\(model)"\(providerField),"choices":[{"index":0,"delta":{},"finish_reason":"stop"}],"usage":{"prompt_tokens":\(promptTokens),"completion_tokens":5,"cost":\(cost)}}
      """)
  }

  static func textResponse(_ text: String, cost: Double = 0, model: String = "test/model") -> ChatCompletionResponse {
    response("""
      {"id":"gen-1","model":"\(model)","choices":[{"index":0,"message":{"role":"assistant","content":\(encodeJSONString(text))},"finish_reason":"stop"}],"usage":{"cost":\(cost)}}
      """)
  }

  /// A minimal manifest entry; `tools` in supported_parameters by default.
  static func manifestModel(id: String, contextLength: Int = 8000, supportsTools: Bool = true) -> String {
    """
    {"id":"\(id)","context_length":\(contextLength),"supported_parameters":[\(supportsTools ? "\"tools\"" : "")],"pricing":{"prompt":"0.000001","completion":"0.000002"}}
    """
  }

  static func manifest(_ entries: String...) -> String {
    "[\(entries.joined(separator: ","))]"
  }

  private static func encodeJSONString(_ text: String) -> String {
    String(decoding: try! JSONEncoder().encode(text), as: UTF8.self)
  }
}
