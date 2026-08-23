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
    public var conversation: String?
    public var attachments: String?
    public var toolOutput: String?
    public var reasoning: String?
    public var apiKey: String?

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
        self.title = Retention.sanitize(title)
        self.authority = authority
        self.threadID = threadID
        self.turnID = turnID
        self.messageTime = messageTime
        self.workingDirectory = workingDirectory
        self.triggerPhrase = Retention.sanitize(String(triggerPhrase.prefix(200)))
        self.excerpt = Retention.sanitize(String(excerpt.prefix(280)))
        let phrase = datePhrase?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.datePhrase = (phrase?.isEmpty == false) ? phrase : nil
        self.dateKind = dateKind
        let owner = ownerName?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.ownerName = (owner?.isEmpty == false) ? owner : nil
        self.ownerKind = ownerKind
        self.conversation = nil
        self.attachments = nil
        self.toolOutput = nil
        self.reasoning = nil
        self.apiKey = nil
    }

    enum CodingKeys: String, CodingKey {
        case idempotencyKey, title, authority, threadID, turnID, messageTime
        case workingDirectory, triggerPhrase, excerpt
        case datePhrase, dateKind, ownerName, ownerKind
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        idempotencyKey = try container.decode(String.self, forKey: .idempotencyKey)
        title = Retention.sanitize(try container.decode(String.self, forKey: .title))
        authority = try container.decode(SourceAuthority.self, forKey: .authority)
        threadID = try container.decode(String.self, forKey: .threadID)
        turnID = try container.decode(String.self, forKey: .turnID)
        messageTime = try container.decode(Date.self, forKey: .messageTime)
        workingDirectory = try container.decode(String.self, forKey: .workingDirectory)
        triggerPhrase = Retention.sanitize(try container.decode(String.self, forKey: .triggerPhrase))
        excerpt = Retention.sanitize(try container.decode(String.self, forKey: .excerpt))
        datePhrase = try container.decodeIfPresent(String.self, forKey: .datePhrase)
        dateKind = try container.decodeIfPresent(DateKind.self, forKey: .dateKind)
        ownerName = try container.decodeIfPresent(String.self, forKey: .ownerName)
        ownerKind = try container.decodeIfPresent(OwnerKind.self, forKey: .ownerKind)
        conversation = nil
        attachments = nil
        toolOutput = nil
        reasoning = nil
        apiKey = nil
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(idempotencyKey, forKey: .idempotencyKey)
        try container.encode(title, forKey: .title)
        try container.encode(authority, forKey: .authority)
        try container.encode(threadID, forKey: .threadID)
        try container.encode(turnID, forKey: .turnID)
        try container.encode(messageTime, forKey: .messageTime)
        try container.encode(workingDirectory, forKey: .workingDirectory)
        try container.encode(triggerPhrase, forKey: .triggerPhrase)
        try container.encode(excerpt, forKey: .excerpt)
        try container.encodeIfPresent(datePhrase, forKey: .datePhrase)
        try container.encodeIfPresent(dateKind, forKey: .dateKind)
        try container.encodeIfPresent(ownerName, forKey: .ownerName)
        try container.encodeIfPresent(ownerKind, forKey: .ownerKind)
    }
}

public enum OwnerKind: String, Codable, Equatable, Sendable {
    case selfPerson = "self"
    case person
    case agent
}

public enum BusinessPriority: String, Codable, Equatable, Sendable {
    case low
    case normal
    case high
    case critical
}

public enum DateUrgency: String, Codable, Equatable, Sendable {
    case none
    case later
    case soon
    case today
    case overdue
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

public enum RecurrenceRule: Equatable, Sendable, Codable {
    case daily
    case weekly(weekday: Int)
    case monthly(day: Int)
}

public struct RecurrenceSeries: Equatable, Sendable, Identifiable {
    public var id: UUID
    public var title: String
    public var rule: RecurrenceRule
    public var isStopped: Bool

    public init(id: UUID, title: String, rule: RecurrenceRule, isStopped: Bool) {
        self.id = id
        self.title = title
        self.rule = rule
        self.isStopped = isStopped
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
    case setReminders(UUID, [Date])
    case setOwner(UUID, String, OwnerKind)
    case confirmAlias(String, UUID)
    case setStatus(UUID, WorkflowStatus)
    case requireAcceptance(UUID, String)
    case satisfyAcceptance(UUID, String)
    case setFollowUp(UUID, Date)
    case proposePlan(PlanProposal)
    case acceptPlan(UUID, [UUID])
    case rejectPlan(UUID)
    case linkSource(UUID, SourceEvidence)
    case setBlockedBy(UUID, UUID)
    case removeBlockedBy(UUID, UUID)
    case setPriority(UUID, BusinessPriority)
    case setRecurrence(UUID, RecurrenceRule)
    case stopRecurrence(UUID)
    case exportBackup(URL)
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
    public var kind: WorkKind
    public var parentID: UUID?
    public var necessary: Bool
    public var progressSummary: String?
    public var priority: BusinessPriority
    public var dateUrgency: DateUrgency
    public var blockedByIDs: [UUID]
    public var hasUnsatisfiedBlockers: Bool
    public var seriesID: UUID?
    public var occurrenceDate: Date?

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
        status: WorkflowStatus = .notStarted,
        kind: WorkKind = .task,
        parentID: UUID? = nil,
        necessary: Bool = true,
        progressSummary: String? = nil,
        priority: BusinessPriority = .normal,
        dateUrgency: DateUrgency = .none,
        blockedByIDs: [UUID] = [],
        hasUnsatisfiedBlockers: Bool = false,
        seriesID: UUID? = nil,
        occurrenceDate: Date? = nil
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
        self.kind = kind
        self.parentID = parentID
        self.necessary = necessary
        self.progressSummary = progressSummary
        self.priority = priority
        self.dateUrgency = dateUrgency
        self.blockedByIDs = blockedByIDs
        self.hasUnsatisfiedBlockers = hasUnsatisfiedBlockers
        self.seriesID = seriesID
        self.occurrenceDate = occurrenceDate
    }
}

public struct ProjectSummary: Equatable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    public var progressSummary: String?

    public init(id: UUID, name: String, progressSummary: String? = nil) {
        self.id = id
        self.name = name
        self.progressSummary = progressSummary
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

    public init(
        threadID: String,
        turnID: String,
        triggerPhrase: String,
        excerpt: String,
        workingDirectory: String
    ) {
        self.threadID = threadID
        self.turnID = turnID
        self.triggerPhrase = String(triggerPhrase.prefix(200))
        self.excerpt = String(excerpt.prefix(280))
        self.workingDirectory = workingDirectory
    }
}

public enum WorkKind: String, Codable, Equatable, Sendable {
    case task
    case milestone
}

public struct PlanItem: Equatable, Sendable, Identifiable, Codable {
    public var id: UUID
    public var title: String
    public var kind: WorkKind
    public var parentID: UUID?
    public var necessary: Bool
    public var datePhrase: String?
    public var dateKind: DateKind?

    public init(
        id: UUID,
        title: String,
        kind: WorkKind = .task,
        parentID: UUID? = nil,
        necessary: Bool = true,
        datePhrase: String? = nil,
        dateKind: DateKind? = nil
    ) {
        self.id = id
        self.title = title
        self.kind = kind
        self.parentID = parentID
        self.necessary = necessary
        self.datePhrase = datePhrase
        self.dateKind = dateKind
    }
}

public struct PlanProposal: Equatable, Sendable, Codable {
    public var idempotencyKey: String
    public var threadID: String
    public var turnID: String
    public var workingDirectory: String
    public var items: [PlanItem]

    public init(
        idempotencyKey: String,
        threadID: String,
        turnID: String,
        workingDirectory: String,
        items: [PlanItem]
    ) {
        self.idempotencyKey = idempotencyKey
        self.threadID = threadID
        self.turnID = turnID
        self.workingDirectory = workingDirectory
        self.items = items
    }
}

public struct PlanDraft: Equatable, Sendable, Identifiable {
    public var id: UUID
    public var items: [PlanItem]

    public init(id: UUID, items: [PlanItem]) {
        self.id = id
        self.items = items
    }
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
    public var plans: [PlanDraft]
    public var milestones: [TaskSummary]
    public var recurrences: [RecurrenceSeries]

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
        owners: [OwnerSummary] = [],
        plans: [PlanDraft] = [],
        milestones: [TaskSummary] = [],
        recurrences: [RecurrenceSeries] = []
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
        self.plans = plans
        self.milestones = milestones
        self.recurrences = recurrences
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
