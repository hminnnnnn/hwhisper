import Foundation

/// Provider preset for the OpenAI-compatible chat-completions endpoint
/// (§2 Decision d): a single client implementation covers Gemini, Groq,
/// a local Ollama server, and any custom OpenAI-compatible endpoint —
/// they all speak the same `/chat/completions` JSON shape.
public enum RefinerProvider: String, Sendable, CaseIterable {
    case gemini
    case groq
    case ollama
    case custom

    public var displayName: String {
        switch self {
        case .gemini: "Gemini"
        case .groq: "Groq"
        case .ollama: "Ollama (로컬)"
        case .custom: "커스텀"
        }
    }

    /// Empty for `.custom` — the caller supplies its own endpoint URL.
    public var defaultEndpoint: String {
        switch self {
        case .gemini: "https://generativelanguage.googleapis.com/v1beta/openai/chat/completions"
        case .groq: "https://api.groq.com/openai/v1/chat/completions"
        case .ollama: "http://localhost:11434/v1/chat/completions"
        case .custom: ""
        }
    }

    public var defaultModel: String {
        switch self {
        case .gemini: "gemini-3.1-flash-lite"
        case .groq: "llama-3.3-70b-versatile"
        case .ollama: "qwen2.5:3b"
        case .custom: ""
        }
    }

    /// The local Ollama server needs no API key; every other preset (and
    /// custom endpoints, which are usually also hosted APIs) does.
    public var requiresAPIKey: Bool {
        self != .ollama
    }
}

/// 정제 강도: `.polish`는 필러 제거/문장부호 교정 등 기존 동작만 하고,
/// `.structure`는 그 위에 나열형 내용의 목록화·화제 분리를 추가로 요청한다.
public enum RefinementStyle: String, Sendable, CaseIterable {
    case polish
    case structure

    public var displayName: String {
        switch self {
        case .polish: "다듬기"
        case .structure: "구조화"
        }
    }
}

/// Connection settings for a single `OpenAICompatibleRefiner` instance.
public struct OpenAICompatibleRefinerConfig: Sendable {
    public let endpoint: URL
    public let model: String
    public let apiKey: String?
    /// Refinement is always async + timeout-bounded (§2 AC2): callers fall
    /// back to raw text on timeout/failure rather than blocking insertion.
    public let timeout: TimeInterval
    public let style: RefinementStyle

    public init(endpoint: URL, model: String, apiKey: String? = nil, timeout: TimeInterval = 8, style: RefinementStyle = .polish) {
        self.endpoint = endpoint
        self.model = model
        self.apiKey = apiKey
        self.timeout = timeout
        self.style = style
    }
}

/// `TextRefiner` backed by any OpenAI-compatible `/chat/completions`
/// endpoint (Decision d). Foundation-only — no AppKit (AC9), so this is
/// reusable from the future iOS target.
public final class OpenAICompatibleRefiner: TextRefiner {
    private let config: OpenAICompatibleRefinerConfig
    private let session: URLSession

    public init(config: OpenAICompatibleRefinerConfig) {
        self.config = config
        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.timeoutIntervalForRequest = config.timeout
        sessionConfig.timeoutIntervalForResource = config.timeout
        self.session = URLSession(configuration: sessionConfig)
    }

    public func refine(_ text: String, context: RefinementContext) async throws -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return text }

        var request = URLRequest(url: config.endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let apiKey = config.apiKey, !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }

        let body = ChatCompletionRequest(
            model: config.model,
            messages: [
                .init(role: "system", content: Self.systemPrompt(context: context, style: config.style)),
                .init(role: "user", content: text)
            ],
            temperature: 0.2,
            // Refined text is rarely longer than the input; a generous
            // multiplier leaves headroom without unbounded cost.
            max_tokens: max(512, trimmed.count * 3)
        )
        request.httpBody = try JSONEncoder().encode(body)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError where error.code == .timedOut {
            throw TextRefinerError.timedOut
        } catch {
            throw TextRefinerError.requestFailed("\(error)")
        }

        guard let httpResponse = response as? HTTPURLResponse, (200..<300).contains(httpResponse.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            let bodyText = String(data: data, encoding: .utf8) ?? ""
            throw TextRefinerError.requestFailed("HTTP \(status): \(bodyText.prefix(200))")
        }

        let decoded: ChatCompletionResponse
        do {
            decoded = try JSONDecoder().decode(ChatCompletionResponse.self, from: data)
        } catch {
            throw TextRefinerError.requestFailed("decode failed: \(error)")
        }

        guard let content = decoded.choices.first?.message.content else {
            throw TextRefinerError.requestFailed("empty completion")
        }
        let refined = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !refined.isEmpty else {
            throw TextRefinerError.requestFailed("empty completion")
        }
        return refined
    }

    /// Korean-aware system prompt (§4 M2 spec): strip fillers, fix
    /// punctuation/spacing (including the KO/EN boundary), never translate
    /// or add content, output only the refined text. `.structure` layers
    /// list/paragraph reorganization on top of every `.polish` rule below.
    private static func systemPrompt(context: RefinementContext, style: RefinementStyle) -> String {
        var prompt = """
        너는 한국어와 영어가 섞인 음성 받아쓰기(dictation) 결과를 다듬는 텍스트 정제기다. 다음 규칙을 반드시 지켜라:
        - 필러 워드(음, 어, 그, like, um 등 의미 없는 간투사)를 제거한다.
        - 문장부호와 띄어쓰기를 올바르게 교정한다. 한글과 영어가 섞인 경계에서도 띄어쓰기를 자연스럽게 맞춘다.
        - 문장을 자연스럽게 다듬되, 원래 의미를 절대 바꾸지 않는다.
        - 어떤 언어로 말했든 그 언어 그대로 유지한다. 번역하지 않는다.
        - 내용을 추가하거나 생략, 요약하지 않는다.
        - 한두 문장짜리 짧은 딕테이션과 여러 문단짜리 긴 메모 모두 같은 원칙으로 처리한다.
        - 결과로 정제된 텍스트만 출력한다. 설명, 마크다운, 따옴표, 코드블록을 덧붙이지 않는다.
        """
        if style == .structure {
            prompt += """

            추가로, 다음 구조화 규칙도 지켜라:
            - 내용이 여러 항목의 나열이면 번호 목록(1. 2. 3.)으로 재구성한다.
            - 서로 다른 주제가 섞여 있으면 단락을 나누어 분리한다.
            - 말을 되돌리거나 정정한 부분("아 그게 아니라...", "아니 다시 말하면" 등)은 최종적으로 의도한 내용만 남기고 정정 이전 발언은 제거한다.
            - 단, 원문에 없는 정보를 추가하거나 새로 만들어내지 않는다.
            - 한두 문장짜리 짧은 입력은 목록화하지 말고 다듬기만 한다 — 나열할 항목이 실제로 여러 개일 때만 목록으로 재구성한다.
            """
        }
        if !context.protectedTerms.isEmpty {
            // Caller passes ONLY terms already present in the input (see
            // PersonalDictionary.protectedTerms(presentIn:)). Still, spell
            // out "don't add them" so the model never treats the list as a
            // cue to insert the term where it doesn't occur.
            prompt += "\n- 다음 용어가 원문에 있으면 그대로 유지한다(수정, 번역, 삭제 금지). 단, 원문에 없으면 절대 새로 추가하지 않는다: " + context.protectedTerms.joined(separator: ", ")
        }
        if let bundleID = context.frontmostBundleID {
            prompt += "\n- 참고로 현재 사용 중인 앱은 \(bundleID)이다. 그 맥락에 맞는 자연스러운 톤으로 다듬어라."
        }
        return prompt
    }
}

private struct ChatCompletionRequest: Encodable {
    struct Message: Encodable {
        let role: String
        let content: String
    }
    let model: String
    let messages: [Message]
    let temperature: Double
    let max_tokens: Int
}

private struct ChatCompletionResponse: Decodable {
    struct Choice: Decodable {
        struct Message: Decodable {
            let content: String
        }
        let message: Message
    }
    let choices: [Choice]
}
