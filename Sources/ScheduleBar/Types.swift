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
    case reviewCandidate(UUID, CandidateDecision)
    case cancel(UUID)
    case archive(UUID)
    case trash(UUID)
    case restoreFromTrash(UUID)
    case permanentlyDelete(UUID)
    case undoLastAutomaticChange
    case resolveDirectory(String, DirectoryDecision)
    case addTag(UUID, String)
}

public enum DirectoryDecision: Equatable, Sendable {
    case create(name: String)
    case link(projectID: UUID)
    case ignore
}

public protocol DirectoryNotifier: Sendable {
    func notifyUnknownDirectory(_ path: String)
}

public struct SilentDirectoryNotifier: DirectoryNotifier {
    public init() {}
    public func notifyUnknownDirectory(_ path: String) {}
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
    public var projectID: UUID?
    public var summaryLine: String

    public init(outcome: Outcome, taskID: UUID? = nil, projectID: UUID? = nil, summaryLine: String? = nil) {
        self.outcome = outcome
        self.taskID = taskID
        self.projectID = projectID
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
    public var projectID: UUID?
    public var tags: [String]

    public init(
        id: UUID,
        title: String,
        notes: String? = nil,
        localPath: String? = nil,
        projectID: UUID? = nil,
        tags: [String] = []
    ) {
        self.id = id
        self.title = title
        self.notes = notes
        self.localPath = localPath
        self.projectID = projectID
        self.tags = tags
    }
}

public struct ProjectSummary: Equatable, Sendable, Identifiable {
    public var id: UUID
    public var name: String

    public init(id: UUID, name: String) {
        self.id = id
        self.name = name
    }
}

public struct DirectoryDiscovery: Equatable, Sendable, Identifiable {
    public var id: String { normalizedPath }
    public var normalizedPath: String

    public init(normalizedPath: String) {
        self.normalizedPath = normalizedPath
    }
}

public struct HistoryEntry: Equatable, Sendable, Identifiable {
    public var id: UUID
    public var summary: String
    public var isAutomatic: Bool
    public var createdAt: Date

    public init(id: UUID, summary: String, isAutomatic: Bool, createdAt: Date) {
        self.id = id
        self.summary = summary
        self.isAutomatic = isAutomatic
        self.createdAt = createdAt
    }
}

public struct SourceEvidence: Equatable, Sendable {
    public var threadID: String
    public var turnID: String
    public var triggerPhrase: String
    public var excerpt: String
    public var workingDirectory: String
}

public struct ObservableState: Equatable, Sendable {
    public var tasks: [TaskSummary]
    public var candidates: [TaskSummary]
    public var archived: [TaskSummary]
    public var trash: [TaskSummary]
    public var history: [HistoryEntry]
    public var projects: [ProjectSummary]
    public var pendingDirectories: [DirectoryDiscovery]

    public var menuTasks: [TaskSummary] { tasks }
    public var consoleTasks: [TaskSummary] { tasks }
    public var candidateCount: Int { candidates.count }

    public init(
        tasks: [TaskSummary],
        candidates: [TaskSummary] = [],
        archived: [TaskSummary] = [],
        trash: [TaskSummary] = [],
        history: [HistoryEntry] = [],
        projects: [ProjectSummary] = [],
        pendingDirectories: [DirectoryDiscovery] = []
    ) {
        self.tasks = tasks
        self.candidates = candidates
        self.archived = archived
        self.trash = trash
        self.history = history
        self.projects = projects
        self.pendingDirectories = pendingDirectories
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
    case notPermitted
    case notFound
    case trashExpired
}
