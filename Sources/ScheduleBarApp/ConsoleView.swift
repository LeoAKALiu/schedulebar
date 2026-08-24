import AppKit
import ScheduleBar
import SwiftUI

struct ConsoleView: View {
    @ObservedObject var session: AppSession
    @State private var selectedSection: ConsoleSection = .all
    @State private var selectedTaskID: TaskSummary.ID?
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 180, ideal: 200)
        } content: {
            content
                .navigationTitle(contentTitle)
        } detail: {
            detail
        }
        .onAppear {
            session.refresh()
            if selectedTaskID == nil {
                selectedTaskID = listedItems.first?.id
            }
        }
        .onChange(of: session.directoryToReview) { _, path in
            if let path {
                selectedSection = .pending(path)
            }
        }
        .onChange(of: session.state.pendingDirectories.map(\.normalizedPath)) { _, pendingPaths in
            if case .pending(let path) = selectedSection, !pendingPaths.contains(path) {
                selectedSection = .all
            }
        }
        .overlay(alignment: .top) {
            if let error = session.errorMessage {
                errorBanner(error)
            }
        }
        .animation(.default, value: session.errorMessage)
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        List(selection: $selectedSection) {
            Section("Inbox") {
                Label("All Tasks", systemImage: "tray.full")
                    .tag(ConsoleSection.all)
                Label("Candidates", systemImage: "sparkles")
                    .badge(sidebarBadge(session.state.candidateCount))
                    .tag(ConsoleSection.candidates)
            }

            Section("Planning") {
                Label("Plans", systemImage: "list.clipboard")
                    .badge(sidebarBadge(session.state.plans.count))
                    .tag(ConsoleSection.plans)
                Label("Milestones", systemImage: "flag")
                    .badge(sidebarBadge(session.state.milestones.count))
                    .tag(ConsoleSection.milestones)
                Label("Recurrence", systemImage: "repeat")
                    .badge(sidebarBadge(session.state.recurrences.count))
                    .tag(ConsoleSection.recurrence)
            }

            Section("Library") {
                Label("Archive", systemImage: "archivebox")
                    .tag(ConsoleSection.archive)
                Label("Trash", systemImage: "trash")
                    .tag(ConsoleSection.trash)
                Label("History", systemImage: "clock.arrow.circlepath")
                    .tag(ConsoleSection.history)
            }

            if !session.state.projects.isEmpty || !session.state.pendingDirectories.isEmpty {
                Section("Projects") {
                    ForEach(session.state.projects) { project in
                        Label {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(project.name)
                                if let summary = project.progressSummary {
                                    Text(summary)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        } icon: {
                            Image(systemName: "folder.fill")
                        }
                        .tag(ConsoleSection.project(project.id))
                    }
                    ForEach(session.state.pendingDirectories) { discovery in
                        Label {
                            VStack(alignment: .leading, spacing: 1) {
                                Text("New directory")
                                Text(discovery.normalizedPath)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                        } icon: {
                            Image(systemName: "folder.badge.questionmark")
                        }
                        .tag(ConsoleSection.pending(discovery.normalizedPath))
                    }
                }
            }

            Section("System") {
                Label("Diagnostics", systemImage: "stethoscope")
                    .tag(ConsoleSection.diagnostics)
            }
        }
    }

    private func sidebarBadge(_ count: Int) -> Text? {
        count > 0 ? Text("\(count)") : nil
    }

    // MARK: - Content column

    @ViewBuilder
    private var content: some View {
        switch selectedSection {
        case .history:
            if session.state.history.isEmpty {
                EmptyStatePlaceholderView(
                    title: "No History Yet",
                    subtitle: "Changes to your tasks will be recorded here.",
                    systemImage: "clock.arrow.circlepath"
                )
            } else {
                List(session.state.history) { entry in
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: entry.isAutomatic ? "wand.and.stars" : "person.fill")
                            .foregroundStyle(entry.isAutomatic ? .purple : .blue)
                            .frame(width: 16)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.summary)
                            Text("\(entry.createdAt.formatted(date: .abbreviated, time: .shortened)) · \(entry.isAutomatic ? "Automatic" : "Human")")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }

        case .diagnostics:
            diagnosticsContent

        case .recurrence:
            if session.state.recurrences.isEmpty {
                EmptyStatePlaceholderView(
                    title: "No Recurring Tasks",
                    subtitle: "Recurring series you create will appear here.",
                    systemImage: "repeat"
                )
            } else {
                List(session.state.recurrences) { series in
                    HStack(spacing: 10) {
                        Image(systemName: "repeat")
                            .foregroundStyle(series.isStopped ? Color.secondary : Color.blue)
                            .frame(width: 16)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(series.title)
                            Text(series.rule.displayDescription)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if series.isStopped {
                            Text("Stopped")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            Button("Stop") { session.stopRecurrence(series.id) }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }

        case .plans:
            if session.state.plans.isEmpty {
                EmptyStatePlaceholderView(
                    title: "No Plans",
                    subtitle: "Proposed plans will appear here for review.",
                    systemImage: "list.clipboard"
                )
            } else {
                List(session.state.plans) { plan in
                    Section {
                        ForEach(plan.items) { item in
                            HStack {
                                Image(systemName: item.parentID == nil ? "circle" : "arrow.turn.down.right")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 14)
                                    .padding(.leading, item.parentID == nil ? 0 : 14)
                                Text(item.title)
                                Spacer()
                                Button("Accept") {
                                    session.acceptPlan(plan.id, [item.id])
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                                .disabled(
                                    item.parentID.map { parentID in
                                        !session.state.tasks.contains { $0.id == parentID }
                                    } ?? false
                                )
                                .help(item.parentID == nil ? "Accept this item" : "Accept its parent first, or accept all")
                            }
                        }
                    } footer: {
                        Button("Accept all") {
                            session.acceptPlan(plan.id, plan.items.map(\.id))
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    }
                }
            }

        default:
            if listedItems.isEmpty {
                emptyState(for: selectedSection)
            } else {
                List(listedItems, selection: $selectedTaskID) { task in
                    TaskRowView(task: task, isCandidate: isCandidate(task))
                        .tag(task.id)
                }
            }
        }
    }

    private var diagnosticsContent: some View {
        Form {
            Section("Components") {
                ForEach(session.state.health) { item in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: item.ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .foregroundStyle(item.ok ? Color.green : Color.yellow)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.name)
                            Text(item.detail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            Section("Queue") {
                Label("Pending inbox: \(session.state.pendingInboxCount)", systemImage: "tray")
            }
            Section("Recent Errors") {
                if session.state.diagnostics.isEmpty {
                    Text("No recent errors")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                ForEach(session.state.diagnostics) { item in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "exclamationmark.octagon")
                            .foregroundStyle(.red)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(item.component) · \(item.code)")
                            Text(item.message)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text("\(item.createdAt.formatted(date: .abbreviated, time: .standard)) · \(item.retryable ? "retryable" : "logged")")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
            }
            Section("Model Miss Detection") {
                ModelKeySection(session: session)
            }
            Section("About Capture") {
                Text(CapturePolicy.chatWorkHelpText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(CapturePolicy.localReconcileHelpText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Actions") {
                Button {
                    session.retryFailures()
                } label: {
                    Label("Retry failed operations", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                Toggle("Open at login", isOn: loginBinding)
                Button {
                    session.exportDiagnostics()
                } label: {
                    Label("Export diagnostics", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .formStyle(.grouped)
    }

    private func emptyState(for section: ConsoleSection) -> some View {
        switch section {
        case .candidates:
            return EmptyStatePlaceholderView(
                title: "No Candidates",
                subtitle: "Tasks captured from Codex sessions will appear here for review.",
                systemImage: "sparkles"
            )
        case .archive:
            return EmptyStatePlaceholderView(
                title: "Archive Is Empty",
                subtitle: "Archived tasks will appear here.",
                systemImage: "archivebox"
            )
        case .trash:
            return EmptyStatePlaceholderView(
                title: "Trash Is Empty",
                subtitle: "Deleted tasks will appear here.",
                systemImage: "trash"
            )
        case .milestones:
            return EmptyStatePlaceholderView(
                title: "No Milestones",
                subtitle: "Milestone tasks will appear here.",
                systemImage: "flag"
            )
        case .project:
            return EmptyStatePlaceholderView(
                title: "No Tasks in Project",
                subtitle: "Tasks linked to this project will appear here.",
                systemImage: "folder"
            )
        default:
            return EmptyStatePlaceholderView(
                title: "No Active Tasks",
                subtitle: "Create your first task to get started.",
                systemImage: "tray",
                actionTitle: "Quick Add…",
                action: { openWindow(id: "quick-add") }
            )
        }
    }

    // MARK: - Detail column

    @ViewBuilder
    private var detail: some View {
        if selectedSection == .history {
            VStack(alignment: .leading, spacing: 12) {
                Label("History Actions", systemImage: "clock.arrow.circlepath")
                    .font(.headline)
                Button("Undo last automatic change") {
                    session.undoAutomatic()
                }
                .buttonStyle(.bordered)
                Button("Export JSON backup") {
                    session.exportBackup()
                }
                .buttonStyle(.bordered)
                Spacer()
            }
            .padding(20)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else if case .pending(let path) = selectedSection {
            DirectoryReviewView(path: path, session: session)
        } else if let task = listedItems.first(where: { $0.id == selectedTaskID }) {
            TaskDetailView(
                task: task,
                session: session,
                isCandidate: isCandidate(task),
                isTrash: selectedSection == .trash,
                evidenceLinks: showsEvidence(for: task) ? session.evidenceLinks(for: task.id) : []
            ) {
                session.confirmCandidate(task.id)
            } reject: {
                session.rejectCandidate(task.id)
            } archive: {
                session.archive(task.id)
            } trash: {
                session.trash(task.id)
            } restore: {
                session.restore(task.id)
            } delete: {
                session.permanentlyDelete(task.id)
            }
        } else {
            EmptyStatePlaceholderView(
                title: "Select a Task",
                subtitle: "Choose an item from the list to view and edit its details.",
                systemImage: "sidebar.right"
            )
        }
    }

    // MARK: - Error banner

    private func errorBanner(_ error: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
            Text(error)
                .font(.callout)
                .foregroundStyle(.primary)
            Spacer()
            Button {
                session.errorMessage = nil
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: 480)
        .glassFloatingBanner(cornerRadius: 10)
        .shadow(color: .black.opacity(0.15), radius: 8, y: 2)
        .padding(.top, 8)
        .transition(.move(edge: .top).combined(with: .opacity))
    }

    // MARK: - Helpers

    private var listedItems: [TaskSummary] {
        switch selectedSection {
        case .candidates: return session.state.candidates
        case .archive: return session.state.archived
        case .trash: return session.state.trash
        case .project(let id):
            return session.state.consoleTasks.filter { $0.projectID == id }
                + session.state.candidates.filter { $0.projectID == id }
        case .milestones: return session.state.milestones
        case .all, .history, .pending, .plans, .recurrence, .diagnostics:
            return session.state.consoleTasks
        }
    }

    private var contentTitle: String {
        switch selectedSection {
        case .all: return "All Tasks"
        case .candidates: return "Candidates"
        case .archive: return "Archive"
        case .trash: return "Trash"
        case .history: return "History"
        case .plans: return "Plans"
        case .milestones: return "Milestones"
        case .recurrence: return "Recurrence"
        case .diagnostics: return "Diagnostics"
        case .pending: return "Review Directory"
        case .project(let id):
            return session.state.projects.first { $0.id == id }?.name ?? "Project"
        }
    }

    private var loginBinding: Binding<Bool> {
        Binding(
            get: { session.state.loginAtStartup },
            set: { session.setLoginAtStartup($0) }
        )
    }

    private func isCandidate(_ task: TaskSummary) -> Bool {
        session.state.candidates.contains { $0.id == task.id }
    }

    private func showsEvidence(for task: TaskSummary) -> Bool {
        switch selectedSection {
        case .all, .project, .candidates: return true
        default: return isCandidate(task)
        }
    }

}

private enum ConsoleSection: Hashable {
    case all
    case candidates
    case archive
    case trash
    case history
    case project(UUID)
    case pending(String)
    case plans
    case milestones
    case recurrence
    case diagnostics
}

// MARK: - Task row

private struct TaskRowView: View {
    let task: TaskSummary
    var isCandidate: Bool = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: isCandidate ? "sparkles" : task.status.iconName)
                .font(.system(size: 13))
                .foregroundStyle(isCandidate ? Color.yellow : task.status.color)
                .frame(width: 18)
            Text(task.title)
                .lineLimit(1)
                .truncationMode(.tail)
                .strikethrough(isInactive)
                .foregroundStyle(titleColor)
            Spacer(minLength: 8)
            if task.priority == .high || task.priority == .critical {
                PriorityPillView(priority: task.priority)
            }
            if let dateText {
                DatePillView(dateText: dateText, isOverdue: task.isOverdue, isToday: task.dateUrgency == .today)
            }
        }
        .padding(.vertical, 2)
    }

    private var isInactive: Bool {
        task.status == .completed || task.status == .cancelled
    }

    private var titleColor: Color {
        if task.hasUnsatisfiedBlockers { return .red }
        if isInactive { return .secondary }
        return .primary
    }

    private var dateText: String? {
        if let phrase = task.datePhrase, !phrase.isEmpty { return phrase }
        let date = task.hardDeadline ?? task.targetDate ?? task.plannedAt ?? task.followUpAt
        return date?.formatted(date: .abbreviated, time: .omitted)
    }
}

// MARK: - Directory review

private struct DirectoryReviewView: View {
    let path: String
    @ObservedObject var session: AppSession
    @State private var name: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("New Codex Directory", systemImage: "folder.badge.questionmark")
                .font(.headline)
            Text(path)
                .font(.callout)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            TextField("Project name", text: $name)
                .textFieldStyle(.roundedBorder)
            HStack(spacing: 8) {
                Button("Create project") {
                    let title = name.isEmpty ? URL(fileURLWithPath: path).lastPathComponent : name
                    session.createProject(for: path, name: title)
                }
                .buttonStyle(.borderedProminent)
                Button("Ignore") {
                    session.ignoreDirectory(path)
                }
            }
            if !session.state.projects.isEmpty {
                Divider()
                Text("Or link to an existing project:")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ForEach(session.state.projects) { project in
                    Button("Link to \(project.name)") {
                        session.linkDirectory(path, to: project.id)
                    }
                    .buttonStyle(.bordered)
                }
            }
            Spacer()
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear {
            if name.isEmpty { name = URL(fileURLWithPath: path).lastPathComponent }
        }
    }
}

// MARK: - Task detail

private struct TaskDetailView: View {
    let task: TaskSummary
    @ObservedObject var session: AppSession
    var isCandidate = false
    var isTrash = false
    var evidenceLinks: [SourceEvidence] = []
    var confirm: () -> Void = {}
    var reject: () -> Void = {}
    var archive: () -> Void = {}
    var trash: () -> Void = {}
    var restore: () -> Void = {}
    var delete: () -> Void = {}
    @State private var editTitle = ""
    @State private var editNotes = ""
    @State private var editPath = ""
    @State private var tagDraft = ""
    @State private var aliasDraft = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            Form {
                detailsSection
                if !isCandidate {
                    workflowSection
                }
                if showsBlockingSection {
                    blockingSection
                }
                infoSection
                if !isCandidate {
                    remindersSection
                    tagsSection
                }
                if !evidenceLinks.isEmpty {
                    evidenceSection
                }
                actionsSection
            }
            .formStyle(.grouped)
        }
        .onAppear {
            loadFields()
        }
        .onChange(of: task.id) { _, _ in
            loadFields()
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(task.title)
                .font(.title2)
                .fontWeight(.semibold)
                .lineLimit(2)
            GlassGroup(spacing: 6) {
                HStack(spacing: 6) {
                    StatusPillView(status: task.status)
                    PriorityPillView(priority: task.priority)
                    if let dateText {
                        DatePillView(dateText: dateText, isOverdue: task.isOverdue, isToday: task.dateUrgency == .today)
                    }
                    if task.hasUnsatisfiedBlockers {
                        Label("Blocked", systemImage: "exclamationmark.octagon.fill")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.red)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .glassPill(tint: .red)
                    }
                    Spacer()
                }
            }
        }
        .padding(16)
    }

    private var dateText: String? {
        if let phrase = task.datePhrase, !phrase.isEmpty { return phrase }
        let date = task.hardDeadline ?? task.targetDate ?? task.plannedAt ?? task.followUpAt
        return date?.formatted(date: .abbreviated, time: .omitted)
    }

    // MARK: Sections

    private var detailsSection: some View {
        Section("Details") {
            if isCandidate || !isTrash {
                TextField("Title", text: $editTitle)
                TextField("Notes", text: $editNotes, axis: .vertical)
                    .lineLimit(3...6)
                TextField("Local path", text: $editPath)
                Button(isCandidate ? "Save changes" : "Save task changes") {
                    if isCandidate {
                        session.editCandidate(task.id, title: editTitle, notes: editNotes, localPath: editPath)
                    } else {
                        session.editTask(task.id, title: editTitle, notes: editNotes, localPath: editPath)
                    }
                }
            } else {
                LabeledContent("Title", value: task.title)
            }
        }
    }

    private var workflowSection: some View {
        Section("Workflow") {
            Picker(selection: statusBinding) {
                ForEach(WorkflowStatus.allCases, id: \.self) { status in
                    Label(status.displayName, systemImage: status.iconName)
                        .tag(status)
                }
            } label: {
                Label("Status", systemImage: task.status.iconName)
            }
            .pickerStyle(.menu)

            Picker(selection: priorityBinding) {
                ForEach(BusinessPriority.allCases, id: \.self) { priority in
                    Label(priority.shortName, systemImage: priority.iconName)
                        .tag(priority)
                }
            } label: {
                Label("Priority", systemImage: task.priority.iconName)
            }
            .pickerStyle(.menu)

            if !session.state.owners.isEmpty {
                Picker(selection: ownerBinding) {
                    ForEach(session.state.owners) { owner in
                        Label(owner.name, systemImage: owner.kind.iconName)
                            .tag(owner.id as UUID?)
                    }
                } label: {
                    Label("Owner", systemImage: "person")
                }
                .pickerStyle(.menu)
            }

            if let owner = session.state.owners.first(where: { $0.id == task.ownerID }) {
                HStack {
                    TextField("Confirm alias for \(owner.name)", text: $aliasDraft)
                    Button("Confirm alias") {
                        let alias = aliasDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !alias.isEmpty else { return }
                        session.confirmAlias(alias, for: owner)
                        aliasDraft = ""
                    }
                }
            }
        }
    }

    private var showsBlockingSection: Bool {
        if !task.blockedByIDs.isEmpty { return true }
        if isCandidate { return false }
        return session.state.tasks.contains { $0.id != task.id && !task.blockedByIDs.contains($0.id) }
    }

    private var blockingSection: some View {
        Section("Blocking") {
            ForEach(task.blockedByIDs, id: \.self) { blockerID in
                HStack {
                    Label(blockerTitle(blockerID), systemImage: "octagon")
                    Spacer()
                    Button("Remove") { session.removeBlockedBy(task.id, blockerID) }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
            }
            if task.hasUnsatisfiedBlockers {
                Text("Unsatisfied blockers keep this task in the blocked workflow.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if !isCandidate {
                blockerPicker
            }
        }
    }

    private var infoSection: some View {
        Section("Info") {
            if isCandidate {
                LabeledContent("Owner", value: task.ownerName ?? "—")
            }
            LabeledContent("Kind", value: task.kind.rawValue)
            if let progress = task.progressSummary {
                LabeledContent("Progress", value: progress)
            }
            if task.seriesID != nil {
                LabeledContent("Occurrence", value: task.occurrenceDate?.formatted(date: .abbreviated, time: .omitted) ?? "—")
            }
        }
    }

    private var remindersSection: some View {
        Section("Reminders") {
            let current = session.reminders(for: task.id)
            if current.isEmpty {
                Text("No reminders")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(current) { reminder in
                    Label(reminder.fireAt.formatted(date: .abbreviated, time: .standard), systemImage: "bell.fill")
                        .font(.callout)
                }
            }
            HStack(spacing: 8) {
                Button("In 1 hour") {
                    session.addReminder(task.id, at: Date().addingTimeInterval(3600))
                }
                Button("Tomorrow 9:00") {
                    session.addReminder(task.id, at: nextNine())
                }
                if !current.isEmpty {
                    Button("Clear", role: .destructive) {
                        session.setReminders(task.id, [])
                    }
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }

    private var tagsSection: some View {
        Section("Tags") {
            if !task.tags.isEmpty {
                FlowLayout(spacing: 6) {
                    ForEach(task.tags, id: \.self) { tag in
                        TagPillView(tag: tag)
                    }
                }
            }
            HStack {
                TextField("Add tag", text: $tagDraft)
                Button("Add tag") {
                    let tag = tagDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !tag.isEmpty else { return }
                    session.addTag(task.id, tag)
                    tagDraft = ""
                }
            }
        }
    }

    private var evidenceSection: some View {
        Section {
            DisclosureGroup("Source Evidence (\(evidenceLinks.count))") {
                ForEach(Array(evidenceLinks.enumerated()), id: \.offset) { _, evidence in
                    LabeledContent("Trigger", value: evidence.triggerPhrase)
                    LabeledContent("Excerpt", value: evidence.excerpt)
                    LabeledContent("Directory", value: evidence.workingDirectory)
                    if let time = evidence.messageTime {
                        LabeledContent("Message time", value: time.formatted(date: .abbreviated, time: .standard))
                    }
                }
            }
        }
    }

    private var actionsSection: some View {
        Section {
            if isCandidate {
                HStack(spacing: 8) {
                    Spacer()
                    Button("Reject", role: .destructive, action: reject)
                        .buttonStyle(.bordered)
                    Button("Confirm", action: confirm)
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                }
            } else if isTrash {
                HStack(spacing: 8) {
                    Button {
                        restore()
                    } label: {
                        Label("Restore", systemImage: "arrow.uturn.backward")
                    }
                    .buttonStyle(.bordered)
                    Button(role: .destructive, action: delete) {
                        Label("Delete Permanently", systemImage: "trash")
                    }
                    .buttonStyle(.bordered)
                }
            } else {
                HStack(spacing: 8) {
                    Button {
                        archive()
                    } label: {
                        Label("Archive", systemImage: "archivebox")
                    }
                    .buttonStyle(.bordered)
                    Button {
                        trash()
                    } label: {
                        Label("Move to Trash", systemImage: "trash")
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
    }

    // MARK: Bindings & helpers

    private var statusBinding: Binding<WorkflowStatus> {
        Binding(
            get: { task.status },
            set: { session.setStatus(task.id, $0) }
        )
    }

    private var priorityBinding: Binding<BusinessPriority> {
        Binding(
            get: { task.priority },
            set: { session.setPriority(task.id, $0) }
        )
    }

    private var ownerBinding: Binding<UUID?> {
        Binding(
            get: { task.ownerID },
            set: { newValue in
                guard let id = newValue,
                      let owner = session.state.owners.first(where: { $0.id == id }) else { return }
                session.setOwner(task.id, owner)
            }
        )
    }

    private var blockerPicker: some View {
        let candidates = session.state.tasks.filter {
            $0.id != task.id && !task.blockedByIDs.contains($0.id)
        }
        return Group {
            if !candidates.isEmpty {
                Menu("Add blocker") {
                    ForEach(candidates) { other in
                        Button(other.title) { session.setBlockedBy(task.id, other.id) }
                    }
                }
            }
        }
    }

    private func loadFields() {
        editTitle = task.title
        editNotes = task.notes ?? ""
        editPath = task.localPath ?? ""
    }

    private func blockerTitle(_ id: UUID) -> String {
        let known = session.state.tasks.first { $0.id == id }?.title
            ?? session.state.trash.first { $0.id == id }?.title
            ?? session.state.archived.first { $0.id == id }?.title
        if let known { return known }
        return "Removed task \(id.uuidString.prefix(8))…"
    }

    private func nextNine() -> Date {
        var calendar = Calendar.current
        calendar.timeZone = .current
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: Date()) ?? Date()
        var components = calendar.dateComponents([.year, .month, .day], from: tomorrow)
        components.hour = 9
        components.minute = 0
        return calendar.date(from: components) ?? tomorrow
    }
}

// MARK: - Model key

private struct ModelKeySection: View {
    @ObservedObject var session: AppSession
    @State private var key = ""

    var body: some View {
        Group {
            SecureField("DeepSeek-compatible API key", text: $key)
            HStack {
                Button("Save key") {
                    let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { return }
                    session.setModelAPIKey(trimmed)
                    key = ""
                }
                Button("Clear key", role: .destructive) { session.clearModelAPIKey() }
            }
            Text("The key is stored only in the macOS Keychain and never exported.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Flow layout

private struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > width, x > 0 {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: width, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
