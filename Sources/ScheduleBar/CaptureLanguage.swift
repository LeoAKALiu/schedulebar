import Foundation

enum CaptureLanguage {
    static let explicitRecordTriggers = ["record as task", "记录为任务", "记为任务"]
    static let rejectedCaptureTriggers = [
        "do not record as task", "don't record as task", "do not record this as task",
        "不要记录为任务", "别记录为任务", "不记录为任务", "不要记录这个计划", "别记录这个计划",
        "never mind", "forget it", "算了",
    ]
    static let planExampleTriggers = ["for example", "e.g.", "例如"]

    static func explicitRecordTrigger(in text: String) -> String? {
        let lowered = text.lowercased()
        return explicitRecordTriggers.first { lowered.contains($0) }
    }

    static func rejectsCapture(_ text: String) -> Bool {
        let lowered = text.lowercased()
        return rejectedCaptureTriggers.contains { lowered.contains($0) }
    }

    static func rejectsPlanDraft(_ text: String) -> Bool {
        let lowered = text.lowercased()
        return rejectsCapture(lowered) || planExampleTriggers.contains { lowered.contains($0) }
    }

    static func title(from text: String) -> String {
        if let trigger = explicitRecordTrigger(in: text) {
            let lowered = text.lowercased()
            if let range = lowered.range(of: trigger) {
                var rest = String(text[range.upperBound...])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                while rest.hasPrefix(":") || rest.hasPrefix("：") {
                    rest = String(rest.dropFirst()).trimmingCharacters(in: .whitespacesAndNewlines)
                }
                if !rest.isEmpty { return Retention.sanitize(String(rest.prefix(140))) }
            }
        }

        let firstLine = text
            .split(whereSeparator: \Character.isNewline)
            .first
            .map(String.init) ?? text
        let trimmed = firstLine.trimmingCharacters(in: .whitespacesAndNewlines)
        let withoutBullet = trimmed.replacingOccurrences(
            of: #"^(?:[-*]\s+|\d+[.)]\s+)"#,
            with: "",
            options: .regularExpression
        )
        return Retention.sanitize(String(withoutBullet.prefix(140)))
    }

    static func dateReference(in text: String) -> (phrase: String, kind: DateKind)? {
        let lowered = text.lowercased()
        let kind: DateKind
        if ["deadline", "due", "no later than", "截止", "最晚"].contains(where: lowered.contains) {
            kind = .hardDeadline
        } else if ["target", "目标日期", "目标时间"].contains(where: lowered.contains) {
            kind = .target
        } else if ["follow up", "follow-up", "跟进", "回访"].contains(where: lowered.contains) {
            kind = .followUp
        } else {
            kind = .planned
        }

        return DateParser.firstSupportedPhrase(in: text).map { ($0, kind) }
    }

    static func planItems(from text: String) -> [PlanItem]? {
        let lowered = text.lowercased()
        guard ["plan", "steps", "milestone", "计划", "步骤", "里程碑", "时间节点"]
            .contains(where: lowered.contains)
        else { return nil }

        struct ParsedLine {
            var indent: Int
            var title: String
        }
        let pattern = #"^(\s*)(?:[-*•]|\d+[.)])\s+(?:\[[ xX]\]\s*)?(.+)$"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let parsed: [ParsedLine] = text.split(whereSeparator: \Character.isNewline).compactMap { rawLine in
            let line = String(rawLine)
            let range = NSRange(line.startIndex..<line.endIndex, in: line)
            guard let match = regex.firstMatch(in: line, range: range),
                  let indentRange = Range(match.range(at: 1), in: line),
                  let titleRange = Range(match.range(at: 2), in: line)
            else { return nil }
            let title = String(line[titleRange]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { return nil }
            return ParsedLine(indent: line[indentRange].count, title: title)
        }
        guard parsed.count >= 2 else { return nil }

        var items: [PlanItem] = []
        var parentStack: [(indent: Int, id: UUID)] = []
        for line in parsed {
            while let last = parentStack.last, last.indent >= line.indent {
                parentStack.removeLast()
            }
            let id = UUID()
            let loweredTitle = line.title.lowercased()
            let kind: WorkKind = ["milestone", "里程碑", "检查点", "time node", "时间节点"]
                .contains(where: loweredTitle.contains) ? .milestone : .task
            let date = dateReference(in: line.title)
            items.append(
                PlanItem(
                    id: id,
                    title: Retention.sanitize(String(line.title.prefix(140))),
                    kind: kind,
                    parentID: parentStack.last?.id,
                    necessary: true,
                    datePhrase: date?.phrase,
                    dateKind: date?.kind
                )
            )
            parentStack.append((line.indent, id))
        }
        return items
    }
}
