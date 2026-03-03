import Foundation

// MARK: - Request Models

struct ChatCompletionRequest: Codable {
    let model: String?
    let messages: [ChatMessage]
    let maxTokens: Int?
    let temperature: Double?
    let topP: Double?
    let stream: Bool?
    let stop: [String]?

    enum CodingKeys: String, CodingKey {
        case model, messages, temperature, stream, stop
        case maxTokens = "max_tokens"
        case topP = "top_p"
    }
}

struct ChatMessage: Codable {
    let role: String
    let content: String

    init(role: String, content: String) {
        self.role = role
        self.content = content
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        role = try container.decode(String.self, forKey: .role)

        // content can be a string or an array of {type, text} objects
        if let str = try? container.decode(String.self, forKey: .content) {
            content = str
        } else if let parts = try? container.decode([ContentPart].self, forKey: .content) {
            content = parts.compactMap { $0.text }.joined()
        } else {
            content = ""
        }
    }

    private enum CodingKeys: String, CodingKey {
        case role, content
    }

    private struct ContentPart: Codable {
        let type: String?
        let text: String?
    }
}

// MARK: - Response Models

struct ChatCompletionResponse: Codable {
    let id: String
    let object: String
    let created: Int
    let model: String
    let choices: [Choice]
    let usage: Usage?

    struct Choice: Codable {
        let index: Int
        let message: ChatMessage
        let finishReason: String?

        enum CodingKeys: String, CodingKey {
            case index, message
            case finishReason = "finish_reason"
        }
    }

    struct Usage: Codable {
        let promptTokens: Int
        let completionTokens: Int
        let totalTokens: Int

        enum CodingKeys: String, CodingKey {
            case promptTokens = "prompt_tokens"
            case completionTokens = "completion_tokens"
            case totalTokens = "total_tokens"
        }
    }
}

struct ChatCompletionChunk: Codable {
    let id: String
    let object: String
    let created: Int
    let model: String
    let choices: [StreamChoice]

    struct StreamChoice: Codable {
        let index: Int
        let delta: DeltaContent
        let finishReason: String?

        enum CodingKeys: String, CodingKey {
            case index, delta
            case finishReason = "finish_reason"
        }
    }

    struct DeltaContent: Codable {
        let role: String?
        let content: String?
    }
}

struct ModelsResponse: Codable {
    let object: String
    let data: [ModelInfo]

    struct ModelInfo: Codable {
        let id: String
        let object: String
        let created: Int
        let ownedBy: String

        enum CodingKeys: String, CodingKey {
            case id, object, created
            case ownedBy = "owned_by"
        }
    }
}

struct ErrorResponse: Codable {
    let error: ErrorDetail

    struct ErrorDetail: Codable {
        let message: String
        let type: String
        let code: String?
    }
}

// MARK: - Helpers

extension ChatCompletionResponse {
    static func create(
        model: String,
        content: String,
        finishReason: String,
        promptTokens: Int,
        completionTokens: Int
    ) -> ChatCompletionResponse {
        ChatCompletionResponse(
            id: "chatcmpl-\(UUID().uuidString.prefix(12))",
            object: "chat.completion",
            created: Int(Date().timeIntervalSince1970),
            model: model,
            choices: [
                Choice(
                    index: 0,
                    message: ChatMessage(role: "assistant", content: content),
                    finishReason: finishReason
                )
            ],
            usage: Usage(
                promptTokens: promptTokens,
                completionTokens: completionTokens,
                totalTokens: promptTokens + completionTokens
            )
        )
    }
}

extension ChatCompletionChunk {
    static func create(
        model: String,
        content: String?,
        role: String? = nil,
        finishReason: String? = nil
    ) -> ChatCompletionChunk {
        ChatCompletionChunk(
            id: "chatcmpl-\(UUID().uuidString.prefix(12))",
            object: "chat.completion.chunk",
            created: Int(Date().timeIntervalSince1970),
            model: model,
            choices: [
                StreamChoice(
                    index: 0,
                    delta: DeltaContent(role: role, content: content),
                    finishReason: finishReason
                )
            ]
        )
    }
}

extension ErrorResponse {
    static func create(message: String, type: String = "server_error", code: String? = nil) -> ErrorResponse {
        ErrorResponse(error: ErrorDetail(message: message, type: type, code: code))
    }
}
