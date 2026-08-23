import Foundation

enum RecurrenceParse: Equatable {
    case none
    case vague
    case complex
    case rule(RecurrenceRule)
}

enum RecurrenceParser {
    static func parse(_ event: CaptureEvent) -> RecurrenceParse {
        parse("\(event.triggerPhrase) \(event.excerpt) \(event.title)")
    }

    static func parse(_ raw: String) -> RecurrenceParse {
        let text = raw.lowercased()
        if isComplex(text) { return .complex }
        if isVague(text) { return .vague }
        if matchesDaily(text) { return .rule(.daily) }
        if let weekday = weeklyWeekday(in: text) { return .rule(.weekly(weekday: weekday)) }
        if let day = monthlyDay(in: text) { return .rule(.monthly(day: day)) }
        return .none
    }

    static func encode(_ rule: RecurrenceRule) -> (kind: String, weekday: Int?, day: Int?) {
        switch rule {
        case .daily: return ("daily", nil, nil)
        case .weekly(let weekday): return ("weekly", weekday, nil)
        case .monthly(let day): return ("monthly", nil, day)
        }
    }

    static func decode(kind: String, weekday: Int?, day: Int?) -> RecurrenceRule? {
        switch kind {
        case "daily": return .daily
        case "weekly":
            guard let weekday else { return nil }
            return .weekly(weekday: weekday)
        case "monthly":
            guard let day else { return nil }
            return .monthly(day: day)
        default: return nil
        }
    }

    static func matches(_ rule: RecurrenceRule, day: Date, calendar: Calendar) -> Bool {
        switch rule {
        case .daily:
            return true
        case .weekly(let weekday):
            return calendar.component(.weekday, from: day) == weekday
        case .monthly(let monthDay):
            return calendar.component(.day, from: day) == monthDay
        }
    }

    static func firstOccurrence(rule: RecurrenceRule, from start: Date, calendar: Calendar) -> Date? {
        var cursor = calendar.startOfDay(for: start)
        for _ in 0..<40 {
            if matches(rule, day: cursor, calendar: calendar) { return cursor }
            guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else { return nil }
            cursor = next
        }
        return nil
    }

    static func occurrenceKey(_ date: Date, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        let year = parts.year ?? 0
        let month = parts.month ?? 0
        let day = parts.day ?? 0
        return String(format: "%04d-%02d-%02d", year, month, day)
    }

    static func date(fromOccurrence key: String) -> Date? {
        let parts = key.split(separator: "-")
        guard parts.count == 3,
              let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2])
        else { return nil }
        return DateParser.date(year: year, month: month, day: day)
    }

    private static func isComplex(_ text: String) -> Bool {
        ["every other", "except", "每隔", "除了", "weekday", "工作日"].contains { text.contains($0) }
    }

    private static func isVague(_ text: String) -> Bool {
        ["so often", "sometimes", "occasionally", "whenever", "偶尔", "有空就", "隔一段时间"].contains { text.contains($0) }
    }

    private static func matchesDaily(_ text: String) -> Bool {
        text.contains("every day") || text.contains("daily") || text.contains("每天") || text.contains("每日")
    }

    private static func weeklyWeekday(in text: String) -> Int? {
        let names: [(Int, [String])] = [
            (1, ["sunday", "周日", "星期日", "周天"]),
            (2, ["monday", "周一", "星期一"]),
            (3, ["tuesday", "周二", "星期二"]),
            (4, ["wednesday", "周三", "星期三"]),
            (5, ["thursday", "周四", "星期四"]),
            (6, ["friday", "周五", "星期五"]),
            (7, ["saturday", "周六", "星期六"]),
        ]
        let looksWeekly = text.contains("every") || text.contains("weekly") || text.contains("每周") || text.contains("每星期")
        guard looksWeekly else { return nil }
        for (value, tokens) in names {
            if tokens.contains(where: { text.contains($0) }) { return value }
        }
        return nil
    }

    private static func monthlyDay(in text: String) -> Int? {
        if text.contains("monthly") || text.contains("every month") || text.contains("每月") {
            let digits = text.split { !$0.isNumber }.compactMap { Int($0) }
            if let day = digits.first, (1...31).contains(day) { return day }
        }
        return nil
    }
}
