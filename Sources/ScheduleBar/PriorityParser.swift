import Foundation

enum PriorityParser {
    static func parse(_ event: CaptureEvent) -> BusinessPriority? {
        parse("\(event.triggerPhrase) \(event.excerpt) \(event.title)")
    }

    static func parse(_ raw: String) -> BusinessPriority? {
        let text = raw.lowercased()
        if text.contains("critical") || text.contains("p0") || text.contains("关键") {
            return .critical
        }
        if text.contains("high priority") || text.contains("p1") || text.contains("高优先级") {
            return .high
        }
        if text.contains("low priority") || text.contains("p3") || text.contains("低优先级") {
            return .low
        }
        if text.contains("normal priority") || text.contains("p2") || text.contains("普通优先级") {
            return .normal
        }
        return nil
    }
}
