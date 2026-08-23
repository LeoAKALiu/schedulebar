import Foundation

enum CaptureClassifier {
    static func outcome(for event: CaptureEvent) -> Outcome {
        if event.authority == .subagent {
            return looksLikeNoise(event) ? .ignored : .candidate
        }
        let text = "\(event.triggerPhrase) \(event.excerpt) \(event.title)".lowercased()
        if looksLikeExplicitRefusal(text) { return .ignored }
        if looksLikeExplicitRecord(text) { return .recorded }
        if looksLikeNoise(text) { return .ignored }
        if looksLikeTentative(text) { return .candidate }
        if looksLikeCommitment(text) { return .recorded }
        return .ignored
    }

    private static func looksLikeExplicitRecord(_ text: String) -> Bool {
        CaptureLanguage.explicitRecordTrigger(in: text) != nil
    }

    private static func looksLikeExplicitRefusal(_ text: String) -> Bool {
        CaptureLanguage.rejectsCapture(text)
    }

    private static func looksLikeTentative(_ text: String) -> Bool {
        ["might", "maybe", "consider", "we could", "暂定", "也许", "考虑"].contains { text.contains($0) }
    }

    private static func looksLikeNoise(_ event: CaptureEvent) -> Bool {
        looksLikeNoise("\(event.triggerPhrase) \(event.excerpt) \(event.title)".lowercased())
    }

    private static func looksLikeNoise(_ text: String) -> Bool {
        [
            "for example", "e.g.", "never mind", "forget it", "read the file", "run tests", "apply_patch",
            "i will not", "we will not", "i won't", "we won't",
            "例如", "算了", "我不会", "我们不会", "不要记录", "不再处理",
        ].contains { text.contains($0) }
    }

    private static func looksLikeCommitment(_ text: String) -> Bool {
        ["i will", "i'll", "we will", "deadline", "due ", "我要", "我会", "截止", "最晚"].contains { text.contains($0) }
    }
}
