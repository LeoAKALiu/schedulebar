import Foundation

enum DateParseStatus: String, Equatable, Sendable {
    case resolved
    case vague
}

struct ParsedDate: Equatable, Sendable {
    var kind: DateKind
    var phrase: String
    var anchor: Date
    var instant: Date?
    var precision: DatePrecision
    var status: DateParseStatus

    var isVague: Bool { status != .resolved }
}

enum DateParser {
    static let timeZone = TimeZone(identifier: "Asia/Shanghai")!

    static func calendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar
    }

    static func date(year: Int, month: Int, day: Int, hour: Int = 0, minute: Int = 0) -> Date? {
        calendar().date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))
    }

    static func parse(phrase raw: String?, kind: DateKind?, at anchor: Date) -> ParsedDate? {
        guard let raw else { return nil }
        let phrase = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !phrase.isEmpty else { return nil }
        let kind = kind ?? .hardDeadline
        let token = normalize(phrase)
        if isVague(token) {
            return ParsedDate(
                kind: kind,
                phrase: phrase,
                anchor: anchor,
                instant: nil,
                precision: .vague,
                status: .vague
            )
        }
        let shanghai = calendar()
        if token == "today" || token == "今天" {
            return resolved(kind: kind, phrase: phrase, anchor: anchor, instant: shanghai.startOfDay(for: anchor), precision: .allDay)
        }
        if token == "tomorrow" || token == "明天" {
            guard let day = shanghai.date(byAdding: .day, value: 1, to: shanghai.startOfDay(for: anchor)) else { return vague(kind: kind, phrase: phrase, anchor: anchor) }
            return resolved(kind: kind, phrase: phrase, anchor: anchor, instant: day, precision: .allDay)
        }
        if token == "yesterday" || token == "昨天" {
            guard let day = shanghai.date(byAdding: .day, value: -1, to: shanghai.startOfDay(for: anchor)) else { return vague(kind: kind, phrase: phrase, anchor: anchor) }
            return resolved(kind: kind, phrase: phrase, anchor: anchor, instant: day, precision: .allDay)
        }
        if token == "后天" {
            guard let day = shanghai.date(byAdding: .day, value: 2, to: shanghai.startOfDay(for: anchor)) else { return vague(kind: kind, phrase: phrase, anchor: anchor) }
            return resolved(kind: kind, phrase: phrase, anchor: anchor, instant: day, precision: .allDay)
        }
        if let instant = parseAllDay(token) {
            return resolved(kind: kind, phrase: phrase, anchor: anchor, instant: instant, precision: .allDay)
        }
        if let instant = parseDateTime(phrase) {
            return resolved(kind: kind, phrase: phrase, anchor: anchor, instant: instant, precision: .dateTime)
        }
        return vague(kind: kind, phrase: phrase, anchor: anchor)
    }

    static func isOverdue(hardDeadline: Date, precision: DatePrecision, now: Date) -> Bool {
        let shanghai = calendar()
        if precision == .allDay {
            guard let nextDay = shanghai.date(byAdding: .day, value: 1, to: shanghai.startOfDay(for: hardDeadline)) else {
                return now > hardDeadline
            }
            return now >= nextDay
        }
        return now > hardDeadline
    }

    static func defaultAllDayHardDeadlineReminders(deadline: Date) -> [Date] {
        let shanghai = calendar()
        let dueDay = shanghai.startOfDay(for: deadline)
        let parts = shanghai.dateComponents([.year, .month, .day], from: dueDay)
        guard let year = parts.year, let month = parts.month, let day = parts.day,
              let dueMorning = date(year: year, month: month, day: day, hour: 9),
              let previous = shanghai.date(byAdding: .day, value: -1, to: dueDay),
              let next = shanghai.date(byAdding: .day, value: 1, to: dueDay)
        else { return [] }
        let previousParts = shanghai.dateComponents([.year, .month, .day], from: previous)
        let nextParts = shanghai.dateComponents([.year, .month, .day], from: next)
        var fires: [Date] = []
        if let year = previousParts.year, let month = previousParts.month, let day = previousParts.day,
           let eve = date(year: year, month: month, day: day, hour: 18) {
            fires.append(eve)
        }
        fires.append(dueMorning)
        if let year = nextParts.year, let month = nextParts.month, let day = nextParts.day,
           let overdueMorning = date(year: year, month: month, day: day, hour: 9) {
            fires.append(overdueMorning)
        }
        return fires
    }

    static func menuBucket(for task: TaskSummary, now: Date) -> MenuDateBucket? {
        if task.isOverdue { return .overdue }
        guard let instant = groupingInstant(for: task) else { return nil }
        let shanghai = calendar()
        let today = shanghai.startOfDay(for: now)
        let day = shanghai.startOfDay(for: instant)
        if day == today { return .today }
        guard let start = shanghai.date(byAdding: .day, value: 1, to: today),
              let end = shanghai.date(byAdding: .day, value: 7, to: today)
        else { return nil }
        if day >= start && day <= end { return .nextSevenDays }
        return nil
    }

    static func groupingInstant(for task: TaskSummary) -> Date? {
        task.hardDeadline ?? task.targetDate ?? task.plannedAt ?? task.followUpAt
    }

    static func dateUrgency(for task: TaskSummary, now: Date) -> DateUrgency {
        if task.isOverdue { return .overdue }
        switch menuBucket(for: task, now: now) {
        case .today: return .today
        case .nextSevenDays: return .soon
        case .overdue: return .overdue
        case nil:
            return groupingInstant(for: task) == nil ? .none : .later
        }
    }

    private static func resolved(
        kind: DateKind,
        phrase: String,
        anchor: Date,
        instant: Date,
        precision: DatePrecision
    ) -> ParsedDate {
        ParsedDate(kind: kind, phrase: phrase, anchor: anchor, instant: instant, precision: precision, status: .resolved)
    }

    private static func vague(kind: DateKind, phrase: String, anchor: Date) -> ParsedDate {
        ParsedDate(kind: kind, phrase: phrase, anchor: anchor, instant: nil, precision: .vague, status: .vague)
    }

    private static func normalize(_ phrase: String) -> String {
        phrase.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func isVague(_ token: String) -> Bool {
        [
            "soon", "later", "someday", "sometime", "whenever", "eventually", "shortly", "asap",
            "尽快", "之后", "以后", "有空", "改天", "最近", "回头", "有时间",
        ].contains(token)
    }

    private static func parseAllDay(_ token: String) -> Date? {
        let parts = token.split(separator: "-")
        guard parts.count == 3, token.count == 10,
              let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2])
        else { return nil }
        return date(year: year, month: month, day: day)
    }

    private static func parseDateTime(_ phrase: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        if let date = formatter.date(from: phrase) { return date }
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: phrase)
    }
}

enum MenuDateBucket: Equatable, Sendable {
    case overdue
    case today
    case nextSevenDays
}
