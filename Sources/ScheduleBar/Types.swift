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

public enum InputEvent: Equatable, Sendable {
    case quickAdd(QuickAddInput)
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

    public init(outcome: Outcome, taskID: UUID? = nil) {
        self.outcome = outcome
        self.taskID = taskID
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

    public var menuTasks: [TaskSummary] { tasks }
    public var consoleTasks: [TaskSummary] { tasks }

    public init(tasks: [TaskSummary]) {
        self.tasks = tasks
    }
}

public enum ScheduleBarError: Error, Equatable {
    case emptyTitle
    case storeUnavailable
}
