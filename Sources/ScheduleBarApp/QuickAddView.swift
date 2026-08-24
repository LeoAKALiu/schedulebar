import ScheduleBar
import SwiftUI

struct QuickAddView: View {
    @ObservedObject var session: AppSession
    @Environment(\.dismiss) private var dismiss

    @State private var title = ""
    @State private var notes = ""
    @State private var localPath = ""
    @FocusState private var isTitleFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Header
            HStack(spacing: 10) {
                Image(systemName: "plus.circle.fill")
                    .font(.system(size: 24))
                    .foregroundStyle(.blue)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Quick Add Task")
                        .font(.headline)
                    Text("Create a new task in your schedule")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            // Input Fields Card
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Label("Task Title", systemImage: "character.cursor.ibeam")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextField("What needs to be done?", text: $title)
                        .textFieldStyle(.roundedBorder)
                        .focused($isTitleFocused)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Label("Notes (Optional)", systemImage: "text.alignleft")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextField("Add details, context, or links...", text: $notes, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .lineLimit(3...5)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Label("Local Path (Optional)", systemImage: "folder")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextField("/path/to/project/or/file", text: $localPath)
                        .textFieldStyle(.roundedBorder)
                }
            }
            .padding(14)
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(Color.secondary.opacity(0.15), lineWidth: 1)
            )

            // Info Tip
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "info.circle")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                Text(CapturePolicy.chatWorkHelpText)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 4)

            // Error Banner
            if let errorMessage = session.errorMessage {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                .padding(8)
                .background(Color.red.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }

            // Footer Buttons
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Add Task") {
                    session.quickAdd(title: title, notes: notes, localPath: localPath)
                    if session.errorMessage == nil {
                        title = ""
                        notes = ""
                        localPath = ""
                        dismiss()
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(.top, 4)
        }
        .padding(20)
        .frame(minWidth: 420, maxWidth: 480)
        .onAppear {
            isTitleFocused = true
        }
    }
}

