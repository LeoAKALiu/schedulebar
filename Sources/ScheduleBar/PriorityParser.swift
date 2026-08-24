import Foundation

enum PriorityParser {
    static func parse(_ event: CaptureEvent) -> BusinessPriority? {
        parse("\(event.triggerPhrase) \(event.excerpt) \(event.title)")
    }

    /// Only explicit priority language changes business priority (issue #10);
    /// descriptive words such as "a critical bug" or "关键路径" must not.
    static func parse(_ raw: String) -> BusinessPriority? {
        let text = raw.lowercased()
        func contains(_ phrase: String) -> Bool {
            text.contains(phrase)
        }
        // p0–p3 must be standalone tokens so identifiers like "p30" don't match.
        func containsLevel(_ level: String) -> Bool {
            text.range(of: "\\b\(level)\\b", options: .regularExpression) != nil
        }
        if containsLevel("p0")
            || contains("priority: critical") || contains("priority critical") || contains("critical priority")
            || contains("优先级:关键") || contains("优先级：关键") || contains("关键优先级") {
            return .critical
        }
        if containsLevel("p1")
            || contains("priority: high") || contains("priority high") || contains("high priority")
            || contains("优先级:高") || contains("优先级：高") || contains("高优先级") {
            return .high
        }
        if containsLevel("p3")
            || contains("priority: low") || contains("priority low") || contains("low priority")
            || contains("优先级:低") || contains("优先级：低") || contains("低优先级") {
            return .low
        }
        if containsLevel("p2")
            || contains("priority: normal") || contains("priority normal") || contains("normal priority")
            || contains("优先级:普通") || contains("优先级：普通") || contains("普通优先级") {
            return .normal
        }
        return nil
    }
}
