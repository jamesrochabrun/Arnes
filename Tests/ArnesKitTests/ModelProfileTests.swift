import XCTest
@testable import ArnesKit
import OpenRouterSwift

/// T5: `ModelProfile.supportsVision` — the one capability read off the manifest that is assumed
/// *off* when the manifest is silent (an image to a text model fails the whole request).
final class ModelProfileTests: XCTestCase {
  private func openRouterModel(_ json: String) throws -> OpenRouterModel {
    try JSONDecoder().decode(OpenRouterModel.self, from: Data(json.utf8))
  }

  func testInputModalitiesDecideVision() throws {
    let vision = try openRouterModel(Fixtures.visionManifestModel(id: "acme/vision"))
    XCTAssertTrue(ModelProfile(model: vision).supportsVision)
    XCTAssertTrue(ModelProfile(model: vision).supportsTools)

    let text = try openRouterModel(Fixtures.manifestModel(id: "acme/text"))
    XCTAssertFalse(ModelProfile(model: text).supportsVision, "no architecture block: no vision")

    let textOnly = try openRouterModel(
      #"{"id":"acme/t","architecture":{"input_modalities":["text"],"output_modalities":["text"]},"supported_parameters":["tools"]}"#)
    XCTAssertFalse(ModelProfile(model: textOnly).supportsVision)
  }

  func testLegacyModalityStringIsReadWhenInputModalitiesIsAbsent() throws {
    let legacyVision = try openRouterModel(
      #"{"id":"acme/legacy","architecture":{"modality":"text+image->text"},"supported_parameters":["tools"]}"#)
    XCTAssertTrue(ModelProfile(model: legacyVision).supportsVision)
    let legacyText = try openRouterModel(
      #"{"id":"acme/legacy-text","architecture":{"modality":"text->text"},"supported_parameters":["tools"]}"#)
    XCTAssertFalse(ModelProfile(model: legacyText).supportsVision)
    // An image *output* model (image generation) is not a vision model.
    let generator = try openRouterModel(
      #"{"id":"acme/paint","architecture":{"modality":"text->image"},"supported_parameters":[]}"#)
    XCTAssertFalse(ModelProfile(model: generator).supportsVision)
    // `input_modalities` wins over the legacy string when both are present.
    let both = try openRouterModel(
      #"{"id":"acme/both","architecture":{"modality":"text+image->text","input_modalities":["text"]},"supported_parameters":[]}"#)
    XCTAssertFalse(ModelProfile(model: both).supportsVision)
  }

  func testLiteLLMSupportsVisionKey() throws {
    let row = try JSONDecoder().decode(LiteLLMModelInfo.self, from: Data("""
      {"model_name": "sonnet", "litellm_params": {"model": "anthropic/claude-sonnet-4-5"},
       "model_info": {"max_input_tokens": 200000, "mode": "chat", "litellm_provider": "anthropic",
                      "supports_function_calling": true, "supports_vision": true}}
      """.utf8))
    XCTAssertTrue(row.profile.supportsVision)
    let silent = try JSONDecoder().decode(LiteLLMModelInfo.self, from: Data("""
      {"model_name": "mystery", "litellm_params": {"model": "custom/whatever"},
       "model_info": {"mode": "chat", "supports_function_calling": true}}
      """.utf8))
    XCTAssertFalse(silent.profile.supportsVision, "a row without the key is assumed text-only")
    XCTAssertTrue(silent.profile.supportsTools, "tools stay assumed on — vision is the one exception")
  }

  func testUnknownModelAndCrossRouterDefaultsAreNoVision() {
    let unknown = ModelProfile(unknownModelId: "openrouter/auto")
    XCTAssertFalse(unknown.supportsVision)
    XCTAssertTrue(unknown.supportsTools, "the documented exception: tools on, vision off")
    let other = ModelProfile(
      id: "gw/alias", contextLength: nil, supportsTools: true, supportsReasoning: false,
      supportsStructuredOutputs: false, promptPricePerToken: nil, completionPricePerToken: nil)
    XCTAssertFalse(other.supportsVision)
    let explicit = ModelProfile(
      id: "gw/vision", contextLength: nil, supportsTools: true, supportsReasoning: false,
      supportsStructuredOutputs: false, promptPricePerToken: nil, completionPricePerToken: nil,
      supportsVision: true)
    XCTAssertTrue(explicit.supportsVision)
  }
}
