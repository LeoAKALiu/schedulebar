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

    public var datePhrase: String?
    public var dateKind: DateKind?
    public var ownerName: String?
    public var ownerKind: OwnerKind?

    public init(
        idempotencyKey: String,
        title: String,
        authority: SourceAuthority,
        threadID: String,
        turnID: String,
        messageTime: Date,
        workingDirectory: String,
        triggerPhrase: String,
        excerpt: String,
        datePhrase: String? = nil,
        dateKind: DateKind? = nil,
        ownerName: String? = nil,
        ownerKind: OwnerKind? = nil
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
        let phrase = datePhrase?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.datePhrase = (phrase?.isEmpty == false) ? phrase : nil
        self.dateKind = dateKind
        let owner = ownerName?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.ownerName = (owner?.isEmpty == false) ? owner : nil
        self.ownerKind = ownerKind
    }
}

public enum OwnerKind: String, Codable, Equatable, Sendable {
    case selfPerson = "self"
    case person
    case agent
}

public enum WorkflowStatus: String, Codable, Equatable, Sendable {
    case notStarted
    case inProgress
    case waitingOnOther
    case blocked
    case pendingAcceptance
    case completed
    case cancelled
}

public struct OwnerSummary: Equatable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    public var kind: OwnerKind

    public init(id: UUID, name: String, kind: OwnerKind) {
        self.id = id
        self.name = name
        self.kind = kind
    }
}

public enum DateKind: String, Codable, Equatable, Sendable {
    case planned
    case target
    case hardDeadline
    case followUp
}

public enum DatePrecision: String, Codable, Equatable, Sendable {
    case allDay
    case dateTime
    case vague
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
    case setReminders(UUID, [Date])
    case setOwner(UUID, String, OwnerKind)
    case confirmAlias(String, UUID)
    case setStatus(UUID, WorkflowStatus)
    case requireAcceptance(UUID, String)
    case satisfyAcceptance(UUID, String)
    case setFollowUp(UUID, Date)
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

public protocol ReminderNotifier: Sendable {
    func notifyReminder(title: String, fireAt: Date)
}

public struct SilentReminderNotifier: ReminderNotifier {
    public init() {}
    public func notifyReminder(title: String, fireAt: Date) {}
}

public struct Reminder: Equatable, Sendable, Identifiable {
    public var id: UUID
    public var fireAt: Date

    public init(id: UUID, fireAt: Date) {
        self.id = id
        self.fireAt = fireAt
    }
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
    public var datePhrase: String?
    public var datePrecision: DatePrecision?
    public var hardDeadline: Date?
    public var plannedAt: Date?
    public var targetDate: Date?
    public var followUpAt: Date?
    public var isOverdue: Bool
    public var ownerID: UUID?
    public var ownerName: String?
    public var ownerKind: OwnerKind?
    public var status: WorkflowStatus

    public init(
        id: UUID,
        title: String,
        notes: String? = nil,
        localPath: String? = nil,
        projectID: UUID? = nil,
        tags: [String] = [],
        datePhrase: String? = nil,
        datePrecision: DatePrecision? = nil,
        hardDeadline: Date? = nil,
        plannedAt: Date? = nil,
        targetDate: Date? = nil,
        followUpAt: Date? = nil,
        isOverdue: Bool = false,
        ownerID: UUID? = nil,
        ownerName: String? = nil,
        ownerKind: OwnerKind? = nil,
        status: WorkflowStatus = .notStarted
    ) {
        self.id = id
        self.title = title
        self.notes = notes
        self.localPath = localPath
        self.projectID = projectID
        self.tags = tags
        self.datePhrase = datePhrase
        self.datePrecision = datePrecision
        self.hardDeadline = hardDeadline
        self.plannedAt = plannedAt
        self.targetDate = targetDate
        self.followUpAt = followUpAt
        self.isOverdue = isOverdue
        self.ownerID = ownerID
        self.ownerName = ownerName
        self.ownerKind = ownerKind
        self.status = status
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
    public var overdue: [TaskSummary]
    public var today: [TaskSummary]
    public var nextSevenDays: [TaskSummary]
    public var waitingOnOthers: [TaskSummary]
    public var owners: [OwnerSummary]

    public var menuTasks: [TaskSummary] { tasks }
    public var consoleTasks: [TaskSummary] { tasks }
    public var candidateCount: Int { candidates.count }
    public var todayCount: Int { today.count }
    public var overdueCount: Int { overdue.count }
    public var unscheduledMenuTasks: [TaskSummary] {
        let grouped = Set(overdue.map(\.id) + today.map(\.id) + nextSevenDays.map(\.id) + waitingOnOthers.map(\.id))
        return menuTasks.filter { !grouped.contains($0.id) && $0.status != .completed && $0.status != .cancelled }
    }

    public init(
        tasks: [TaskSummary],
        candidates: [TaskSummary] = [],
        archived: [TaskSummary] = [],
        trash: [TaskSummary] = [],
        history: [HistoryEntry] = [],
        projects: [ProjectSummary] = [],
        pendingDirectories: [DirectoryDiscovery] = [],
        overdue: [TaskSummary] = [],
        today: [TaskSummary] = [],
        nextSevenDays: [TaskSummary] = [],
        waitingOnOthers: [TaskSummary] = [],
        owners: [OwnerSummary] = []
    ) {
        self.tasks = tasks
        self.candidates = candidates
        self.archived = archived
        self.trash = trash
        self.history = history
        self.projects = projects
        self.pendingDirectories = pendingDirectories
        self.overdue = overdue
        self.today = today
        self.nextSevenDays = nextSevenDays
        self.waitingOnOthers = waitingOnOthers
        self.owners = owners
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
