import Foundation

public struct MissedCandidateRequest: Equatable, Sendable {
    public var turnText: String
    public var threadID: String
    public var turnID: String

    public init(turnText: String, threadID: String, turnID: String) {
        self.turnText = turnText
        self.threadID = threadID
        self.turnID = turnID
    }
}

public enum ModelMissResult: Equatable, Sendable {
    case candidates([String])
    case failed(code: String, message: String)
}

public protocol ModelGateway: Sendable {
    func detectMissedCandidates(_ request: MissedCandidateRequest, apiKey: String?) async -> ModelMissResult
}

public struct SilentModelGateway: ModelGateway {
    public init() {}

    public func detectMissedCandidates(_ request: MissedCandidateRequest, apiKey: String?) async -> ModelMissResult {
        .candidates([])
    }
}

public final class ScriptedModelGateway: ModelGateway, @unchecked Sendable {
    public var result: ModelMissResult
    public var delay: TimeInterval
    private let lock = NSLock()
    private var recorded: [MissedCandidateRequest] = []

    public init(result: ModelMissResult, delay: TimeInterval = 0) {
        self.result = result
        self.delay = delay
    }

    public var requests: [MissedCandidateRequest] {
        lock.lock(); defer { lock.unlock() }
        return recorded
    }

    public func detectMissedCandidates(_ request: MissedCandidateRequest, apiKey: String?) async -> ModelMissResult {
        record(request)
        if delay > 0 {
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        }
        return result
    }

    private func record(_ request: MissedCandidateRequest) {
        lock.lock(); defer { lock.unlock() }
        recorded.append(request)
    }
}

public struct HTTPModelGateway: ModelGateway {
    public static let baseURLDefaultsKey = "SCHEDULEBAR_MODEL_BASE_URL"
    public static let modelDefaultsKey = "SCHEDULEBAR_MODEL_NAME"

    public var baseURL: URL
    public var model: String
    public var session: URLSession
    public var timeout: TimeInterval

    public init(
        baseURL: URL = URL(string: "https://api.deepseek.com")!,
        model: String = "deepseek-chat",
        session: URLSession = .shared,
        timeout: TimeInterval = 8
    ) {
        self.baseURL = baseURL
        self.model = model
        self.session = session
        self.timeout = timeout
    }

    /// User-configured compatible API endpoint (issue #13: the gateway must
    /// adapt to a user-chosen API shape without binding domain behavior).
    public static func userConfigured(defaults: UserDefaults = .standard) -> HTTPModelGateway {
        let environment = ProcessInfo.processInfo.environment
        let baseURL = defaults.string(forKey: baseURLDefaultsKey).flatMap(URL.init(string:))
            ?? environment["SCHEDULEBAR_MODEL_BASE_URL"].flatMap(URL.init(string:))
        let model = defaults.string(forKey: modelDefaultsKey)
            ?? environment["SCHEDULEBAR_MODEL_NAME"]
        return HTTPModelGateway(
            baseURL: baseURL ?? URL(string: "https://api.deepseek.com")!,
            model: model?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "deepseek-chat"
        )
    }

    public func detectMissedCandidates(_ request: MissedCandidateRequest, apiKey: String?) async -> ModelMissResult {
        guard let apiKey, !apiKey.isEmpty else { return .candidates([]) }
        var urlRequest = URLRequest(url: baseURL.appending(path: "v1/chat/completions"))
        urlRequest.httpMethod = "POST"
        urlRequest.timeoutInterval = timeout
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        let body: [String: Any] = [
            "model": model,
            "messages": [
                [
                    "role": "system",
                    "content": "List missed follow-up tasks from this turn. Reply with one title per line, or NONE.",
                ],
                ["role": "user", "content": request.turnText],
            ],
        ]
        urlRequest.httpBody = try? JSONSerialization.data(withJSONObject: body)
        do {
            let (data, response) = try await session.data(for: urlRequest)
            if let http = response as? HTTPURLResponse, http.statusCode == 429 {
                return .failed(code: "model_rate_limited", message: "rate limited")
            }
            if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
                return .failed(code: "model_network", message: "HTTP \(http.statusCode)")
            }
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let choices = object["choices"] as? [[String: Any]],
                  let message = choices.first?["message"] as? [String: Any],
                  let content = message["content"] as? String
            else {
                return .failed(code: "model_parse", message: "unreadable response")
            }
            let titles = content
                .split(whereSeparator: \.isNewline)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty && $0.uppercased() != "NONE" }
            return .candidates(titles)
        } catch let error as URLError where error.code == .timedOut {
            return .failed(code: "model_timeout", message: "timed out")
        } catch {
            return .failed(code: "model_network", message: "network failure")
        }
    }
}
