import Foundation

public struct QuickAddInput: Equatable, Sendable {
    public var title: String
    public var notes: String?
    public var localPath: String?

    public init(title: String, notes: String? = nil, localPath: String? = nil) {
        self.title = title
        self.notes = notes
        self.localPath = localPath
    }
}

public enum SourceAuthority: String, Codable, Equatable, Sendable {
    case human
    case mainConversation
    case subagent
}

public struct CaptureEvent: Equatable, Sendable, Codable {
    public var idempotencyKey: String
    public var title: String
    public var authority: SourceAuthority
    public var threadID: String
    public var turnID: String
    public var messageTime: Date
    public var workingDirectory: String
    public var triggerPhrase: String
    public var excerpt: String

    public init(
        idempotencyKey: String,
        title: String,
        authority: SourceAuthority,
        threadID: String,
        turnID: String,
        messageTime: Date,
        workingDirectory: String,
        triggerPhrase: String,
        excerpt: String
    ) {
        self.idempotencyKey = idempotencyKey
        self.title = title
        self.authority = authority
        self.threadID = threadID
        self.turnID = turnID
        self.messageTime = messageTime
        self.workingDirectory = workingDirectory
        self.triggerPhrase = String(triggerPhrase.prefix(200))
        self.excerpt = String(excerpt.prefix(280))
    }
}

public enum InputEvent: Equatable, Sendable {
    case quickAdd(QuickAddInput)
    case capture(CaptureEvent)
}

public enum Outcome: String, Equatable, Sendable {
    case recorded
    case candidate
    case ignored
    case duplicate
    case notRecorded
}

public struct Receipt: Equatable, Sendable {
    public var outcome: Outcome
    public var taskID: UUID?
    public var summaryLine: String

    public init(outcome: Outcome, taskID: UUID? = nil, summaryLine: String? = nil) {
        self.outcome = outcome
        self.taskID = taskID
        self.summaryLine = summaryLine ?? outcome.defaultSummaryLine
    }
}

extension Outcome {
    public var defaultSummaryLine: String {
        switch self {
        case .recorded: return "Recorded"
        case .candidate: return "Saved as candidate"
        case .ignored: return "Ignored"
        case .duplicate: return "Already recorded"
        case .notRecorded: return "未记录"
        }
    }
}

public struct TaskSummary: Equatable, Sendable, Identifiable {
    public var id: UUID
    public var title: String
    public var notes: String?
    public var localPath: String?

    public init(id: UUID, title: String, notes: String? = nil, localPath: String? = nil) {
        self.id = id
        self.title = title
        self.notes = notes
        self.localPath = localPath
    }
}

public struct ObservableState: Equatable, Sendable {
    public var tasks: [TaskSummary]
    public var candidates: [TaskSummary]

    public var menuTasks: [TaskSummary] { tasks }
    public var consoleTasks: [TaskSummary] { tasks }
    public var candidateCount: Int { candidates.count }

    public init(tasks: [TaskSummary], candidates: [TaskSummary] = []) {
        self.tasks = tasks
        self.candidates = candidates
    }
}

public enum CandidateDecision: Equatable, Sendable {
    case confirm
    case reject
    case edit(QuickAddInput)
}

public enum ScheduleBarError: Error, Equatable {
    case emptyTitle
    case storeUnavailable
}
