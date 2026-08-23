import Foundation

enum CaptureClassifier {
    static func outcome(for event: CaptureEvent) -> Outcome {
        if event.authority == .subagent {
            return looksLikeNoise(event) ? .ignored : .candidate
        }
        let text = "\(event.triggerPhrase) \(event.excerpt) \(event.title)".lowercased()
        if looksLikeExplicitRecord(text) { return .recorded }
        if looksLikeNoise(text) { return .ignored }
        if looksLikeTentative(text) { return .candidate }
        if looksLikeCommitment(text) { return .recorded }
        return .ignored
    }

    private static func looksLikeExplicitRecord(_ text: String) -> Bool {
        text.contains("record as task") || text.contains("记录为任务") || text.contains("记为任务")
    }

    private static func looksLikeTentative(_ text: String) -> Bool {
        ["might", "maybe", "consider", "we could", "暂定", "也许", "考虑"].contains { text.contains($0) }
    }

    private static func looksLikeNoise(_ event: CaptureEvent) -> Bool {
        looksLikeNoise("\(event.triggerPhrase) \(event.excerpt) \(event.title)".lowercased())
    }

    private static func looksLikeNoise(_ text: String) -> Bool {
        ["for example", "e.g.", "never mind", "forget it", "read the file", "run tests", "apply_patch", "例如", "算了"].contains { text.contains($0) }
    }

    private static func looksLikeCommitment(_ text: String) -> Bool {
        ["i will", "i'll", "we will", "deadline", "due ", "我要", "我会"].contains { text.contains($0) }
    }
}
