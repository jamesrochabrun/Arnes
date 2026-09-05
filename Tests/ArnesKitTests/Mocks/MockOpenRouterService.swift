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
  /// A native endpoint refusing a request with the given message — what a 400 body reads as
  /// once the session stringifies it (`"\(error)"` includes the text).
  case nativeRefusal(String)
}

/// Scriptable mock: streaming calls consume `chunkScripts` in order, non-streaming
/// calls consume `chatResponses`, and every chat request is recorded for inspection.
final class MockOpenRouterService: OpenRouterService, @unchecked Sendable {
  private let lock = NSLock()

  var chunkScripts: [[ChatCompletionChunk]] = []
  /// Per-model scripts, consulted before `chunkScripts` — required when concurrent
  /// callers (panel candidates) would otherwise race on the shared queue.
  var chunkScriptsByModel: [String: [[ChatCompletionChunk]]] = [:]
  /// Consulted ahead of both queues when set: a script chosen from the request itself (its
  /// messages tell a run's first step from its second), so concurrent runs over one model can
  /// each get a coherent two-step conversation — the shared queues are consumed in arrival
  /// order and would hand one run's second script to another run's first request. nil from
  /// the selector falls through to the queues.
  var chunkScriptSelector: (@Sendable (ChatCompletionRequest) -> [ChatCompletionChunk]?)?
  var chatResponses: [ChatCompletionResponse] = []
  var messagesEventScripts: [[MessagesStreamEvent]] = []
  var responsesEventScripts: [[ResponsesStreamEvent]] = []
  /// Errors a `/messages` request throws *instead of* consuming a script, in order — one per
  /// request, consumed first. How a test stages a native refusal with a specific message.
  var messagesStreamErrors: [Error] = []
  var manifestJSON = "[]"
  /// Awaited before a chat stream yields its first chunk — a latch here holds a stream open
  /// until something else happens (another stream starting), which is how concurrency
  /// tests prove two runs overlap instead of relying on timing.
  var streamGate: (@Sendable (ChatCompletionRequest) async -> Void)?
  /// Errors a chat request throws *instead of* consuming a script, in order — one per request,
  /// consumed first (the `messagesStreamErrors` shape for chat). How a test stages an HTTP-level
  /// refusal (a 429, a 503, a lost connection) that arrives before any chunk.
  var chatStreamErrors: [Error] = []
  /// One entry per chat stream *opened* (consumed alongside its script, after the errors above):
  /// a non-nil error makes that stream fail after yielding every chunk of its script — the
  /// mid-stream failure, before or after output depending on the script's length. nil = the
  /// stream finishes normally.
  var chatStreamTrailingErrors: [Error?] = []
  /// The `chatStreamTrailingErrors` shape for `/messages`: one entry per `/messages` stream
  /// *opened* (consumed alongside its script), a non-nil error failing that stream after every
  /// event of its script — an SSE error event relayed mid-stream, a connection lost inside the
  /// stream — before or after output depending on the script's length. nil = a normal finish.
  var messagesStreamTrailingErrors: [Error?] = []
  private var recordedRequests: [ChatCompletionRequest] = []
  private var recordedMessagesRequests: [MessagesRequest] = []
  private var recordedResponsesRequests: [ResponsesRequest] = []

  var requests: [ChatCompletionRequest] {
    lock.lock()
    defer { lock.unlock() }
    return recordedRequests
  }

  var messagesRequests: [MessagesRequest] {
    lock.lock()
    defer { lock.unlock() }
    return recordedMessagesRequests
  }

  var responsesRequests: [ResponsesRequest] {
    lock.lock()
    defer { lock.unlock() }
    return recordedResponsesRequests
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
    let staged: Result<([ChatCompletionChunk]?, Error?), Error> = lock.withLock {
      recordedRequests.append(request)
      if !chatStreamErrors.isEmpty {
        return .failure(chatStreamErrors.removeFirst())
      }
      let trailing: Error? = chatStreamTrailingErrors.isEmpty ? nil : chatStreamTrailingErrors.removeFirst()
      if let chosen = chunkScriptSelector?(request) {
        return .success((chosen, trailing))
      }
      if let model = request.model, var scripts = chunkScriptsByModel[model], !scripts.isEmpty {
        let first = scripts.removeFirst()
        chunkScriptsByModel[model] = scripts
        return .success((first, trailing))
      }
      return .success((chunkScripts.isEmpty ? nil : chunkScripts.removeFirst(), trailing))
    }
    let (chosen, trailing) = try staged.get()
    guard let script = chosen else { throw MockError.scriptExhausted }
    let gate = lock.withLock { streamGate }
    return AsyncThrowingStream { continuation in
      guard let gate else {
        for chunk in script {
          continuation.yield(chunk)
        }
        continuation.finish(throwing: trailing)
        return
      }
      Task {
        await gate(request)
        for chunk in script {
          continuation.yield(chunk)
        }
        continuation.finish(throwing: trailing)
      }
    }
  }

  func messageStream(_ request: MessagesRequest) async throws -> AsyncThrowingStream<MessagesStreamEvent, Error> {
    let staged: Result<([MessagesStreamEvent]?, Error?), Error> = lock.withLock {
      recordedMessagesRequests.append(request)
      if !messagesStreamErrors.isEmpty {
        return .failure(messagesStreamErrors.removeFirst())
      }
      let trailing: Error? = messagesStreamTrailingErrors.isEmpty ? nil : messagesStreamTrailingErrors.removeFirst()
      return .success((messagesEventScripts.isEmpty ? nil : messagesEventScripts.removeFirst(), trailing))
    }
    let (chosen, trailing) = try staged.get()
    guard let script = chosen else { throw MockError.scriptExhausted }
    return AsyncThrowingStream { continuation in
      for event in script {
        continuation.yield(event)
      }
      continuation.finish(throwing: trailing)
    }
  }

  func responseStream(_ request: ResponsesRequest) async throws -> AsyncThrowingStream<ResponsesStreamEvent, Error> {
    let script: [ResponsesStreamEvent]? = lock.withLock {
      recordedResponsesRequests.append(request)
      return responsesEventScripts.isEmpty ? nil : responsesEventScripts.removeFirst()
    }
    guard let script else { throw MockError.scriptExhausted }
    return AsyncThrowingStream { continuation in
      for event in script {
        continuation.yield(event)
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

  static func messagesEvent(_ json: String) -> MessagesStreamEvent {
    try! JSONDecoder().decode(MessagesStreamEvent.self, from: Data(json.utf8))
  }

  static func responsesEvent(_ json: String) -> ResponsesStreamEvent {
    try! JSONDecoder().decode(ResponsesStreamEvent.self, from: Data(json.utf8))
  }

  /// Round-trips any Encodable through JSON for structural assertions on
  /// encode-only request types.
  static func jsonValue<T: Encodable>(_ value: T) -> JSONValue {
    try! JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(value))
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

  /// A manifest entry for a thinking model: `tools` + `reasoning` in supported_parameters and,
  /// when given, `top_provider.max_completion_tokens` (the `/messages` output ceiling).
  static func reasoningManifestModel(id: String, contextLength: Int = 200000, maxCompletionTokens: Int? = nil) -> String {
    let topProvider = maxCompletionTokens.map {
      #","top_provider":{"context_length":\#(contextLength),"max_completion_tokens":\#($0)}"#
    } ?? ""
    return """
    {"id":"\(id)","context_length":\(contextLength),"supported_parameters":["tools","reasoning"],"pricing":{"prompt":"0.000001","completion":"0.000002"}\(topProvider)}
    """
  }

  /// A chat chunk whose delta carries `reasoning_details` fragments (raw JSON array text).
  static func reasoningDetailsChunk(_ fragmentsJSON: String, model: String = "test/model") -> ChatCompletionChunk {
    chunk("""
      {"model":"\(model)","choices":[{"index":0,"delta":{"reasoning_details":\(fragmentsJSON)}}]}
      """)
  }

  /// The final chunk of a chat stream with an explicit `finish_reason` (`length` = the reply hit
  /// the output limit) and usage — `usageChunk` always says `stop`.
  static func finishChunk(_ reason: String, cost: Double = 0.01, model: String = "test/model") -> ChatCompletionChunk {
    chunk("""
      {"model":"\(model)","choices":[{"index":0,"delta":{},"finish_reason":"\(reason)"}],"usage":{"prompt_tokens":10,"completion_tokens":5,"cost":\(cost)}}
      """)
  }

  /// A manifest entry for a model that takes images: `architecture.input_modalities` names
  /// `image` (T5, what `ModelProfile.supportsVision` reads); `tools` in supported_parameters, and
  /// `reasoning` too when asked (for the adaptive `think` omission).
  static func visionManifestModel(id: String, contextLength: Int = 128000, supportsReasoning: Bool = false) -> String {
    let parameters = supportsReasoning ? #""tools","reasoning""# : #""tools""#
    return """
    {"id":"\(id)","context_length":\(contextLength),"architecture":{"modality":"text+image->text","input_modalities":["text","image"],"output_modalities":["text"]},"supported_parameters":[\(parameters)],"pricing":{"prompt":"0.000001","completion":"0.000002"}}
    """
  }

  /// The final chunk of a chat stream whose usage says how many prompt tokens were read from the
  /// provider's prompt cache (`prompt_tokens_details.cached_tokens`, a subset of `prompt_tokens`
  /// — the OpenAI accounting OpenRouter and LiteLLM normalize to). `usageChunk` carries no
  /// details at all.
  static func cachedUsageChunk(
    cost: Double,
    model: String = "test/model",
    promptTokens: Int = 1000,
    cachedTokens: Int = 700)
    -> ChatCompletionChunk
  {
    chunk("""
      {"model":"\(model)","choices":[{"index":0,"delta":{},"finish_reason":"stop"}],"usage":{"prompt_tokens":\(promptTokens),"completion_tokens":5,"cost":\(cost),"prompt_tokens_details":{"cached_tokens":\(cachedTokens)}}}
      """)
  }

  private static func encodeJSONString(_ text: String) -> String {
    String(decoding: try! JSONEncoder().encode(text), as: UTF8.self)
  }
}
