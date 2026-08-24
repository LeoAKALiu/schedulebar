import AppKit
import ScheduleBar
import SwiftUI

// MARK: - Enums CaseIterable

extension WorkflowStatus: CaseIterable {
    public static var allCases: [WorkflowStatus] {
        [.notStarted, .inProgress, .waitingOnOther, .blocked, .pendingAcceptance, .completed, .cancelled]
    }
}

extension BusinessPriority: CaseIterable {
    public static var allCases: [BusinessPriority] {
        [.low, .normal, .high, .critical]
    }
}

// MARK: - WorkflowStatus Extensions

extension WorkflowStatus {
    public var displayName: String {
        switch self {
        case .notStarted: return "Not Started"
        case .inProgress: return "In Progress"
        case .waitingOnOther: return "Waiting on Other"
        case .blocked: return "Blocked"
        case .pendingAcceptance: return "Pending Acceptance"
        case .completed: return "Completed"
        case .cancelled: return "Cancelled"
        }
    }

    public var iconName: String {
        switch self {
        case .notStarted: return "circle"
        case .inProgress: return "arrow.triangle.2.circlepath.circle.fill"
        case .waitingOnOther: return "person.crop.circle.badge.clock.fill"
        case .blocked: return "exclamationmark.octagon.fill"
        case .pendingAcceptance: return "hourglass.circle.fill"
        case .completed: return "checkmark.circle.fill"
        case .cancelled: return "xmark.circle.fill"
        }
    }

    public var color: Color {
        switch self {
        case .notStarted: return .secondary
        case .inProgress: return .blue
        case .waitingOnOther: return .orange
        case .blocked: return .red
        case .pendingAcceptance: return .purple
        case .completed: return .green
        case .cancelled: return .secondary
        }
    }
}

// MARK: - BusinessPriority Extensions

extension BusinessPriority {
    public var displayName: String {
        switch self {
        case .low: return "Low Priority"
        case .normal: return "Normal Priority"
        case .high: return "High Priority"
        case .critical: return "Critical Priority"
        }
    }

    public var shortName: String {
        switch self {
        case .low: return "Low"
        case .normal: return "Normal"
        case .high: return "High"
        case .critical: return "Critical"
        }
    }

    public var iconName: String {
        switch self {
        case .low: return "arrow.down"
        case .normal: return "minus"
        case .high: return "arrow.up"
        case .critical: return "exclamationmark.3"
        }
    }

    public var color: Color {
        switch self {
        case .low: return .secondary
        case .normal: return .blue
        case .high: return .orange
        case .critical: return .red
        }
    }
}

// MARK: - OwnerKind Extensions

extension OwnerKind {
    public var iconName: String {
        switch self {
        case .selfPerson: return "person.crop.circle.fill"
        case .person: return "person.fill"
        case .agent: return "sparkles"
        }
    }
}

// MARK: - DateUrgency Extensions

extension DateUrgency {
    public var displayName: String {
        switch self {
        case .none: return "No urgency"
        case .later: return "Later"
        case .soon: return "Soon"
        case .today: return "Due Today"
        case .overdue: return "Overdue"
        }
    }

    public var color: Color {
        switch self {
        case .overdue: return .red
        case .today: return .orange
        case .soon: return .yellow
        case .later: return .blue
        case .none: return .secondary
        }
    }
}

// MARK: - Reusable UI Badges & Components

struct StatusPillView: View {
    let status: WorkflowStatus

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: status.iconName)
                .font(.system(size: 10, weight: .bold))
            Text(status.displayName)
                .font(.system(size: 11, weight: .medium))
        }
        .foregroundStyle(status.color)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(status.color.opacity(0.12))
        .clipShape(Capsule())
    }
}

struct PriorityPillView: View {
    let priority: BusinessPriority

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: priority.iconName)
                .font(.system(size: 9, weight: .bold))
            Text(priority.shortName)
                .font(.system(size: 11, weight: .medium))
        }
        .foregroundStyle(priority.color)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(priority.color.opacity(0.12))
        .clipShape(Capsule())
    }
}

struct DatePillView: View {
    let dateText: String
    var isOverdue: Bool = false
    var isToday: Bool = false

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: isOverdue ? "exclamationmark.circle.fill" : (isToday ? "sun.max.fill" : "calendar"))
                .font(.system(size: 9, weight: .bold))
            Text(dateText)
                .font(.system(size: 11, weight: .medium))
        }
        .foregroundStyle(color)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(color.opacity(0.12))
        .clipShape(Capsule())
    }

    private var color: Color {
        if isOverdue { return .red }
        if isToday { return .orange }
        return .blue
    }
}

struct TagPillView: View {
    let tag: String
    var onRemove: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "tag.fill")
                .font(.system(size: 8))
                .foregroundStyle(.secondary)
            Text(tag)
                .font(.system(size: 11, weight: .regular))
                .foregroundStyle(.primary)
            if let onRemove {
                Button(action: onRemove) {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .padding(.leading, 2)
            }
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(Color(nsColor: .controlBackgroundColor))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color.secondary.opacity(0.2), lineWidth: 1)
        )
        .clipShape(Capsule())
    }
}

struct EmptyStatePlaceholderView: View {
    let title: String
    let subtitle: String
    var systemImage: String = "checklist"
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 40))
                .foregroundStyle(.tertiary)
            Text(title)
                .font(.headline)
                .foregroundStyle(.secondary)
            Text(subtitle)
                .font(.subheadline)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 280)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.bordered)
                    .controlSize(.regular)
                    .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(32)
    }
}
