import ScheduleBar
import SwiftUI

struct CandidateEditView: View {
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
                Image(systemName: "sparkles")
                    .font(.system(size: 24))
                    .foregroundStyle(.yellow)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Edit Candidate")
                        .font(.headline)
                    Text("Review and adjust candidate task details")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            if let candidate = session.candidateBeingEdited {
                VStack(alignment: .leading, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Label("Title", systemImage: "character.cursor.ibeam")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        TextField("Title", text: $title)
                            .textFieldStyle(.roundedBorder)
                            .focused($isTitleFocused)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Label("Notes (Optional)", systemImage: "text.alignleft")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        TextField("Notes", text: $notes, axis: .vertical)
                            .textFieldStyle(.roundedBorder)
                            .lineLimit(3...5)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Label("Local Path (Optional)", systemImage: "folder")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        TextField("Local path", text: $localPath)
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

                HStack {
                    Button("Cancel") { dismiss() }
                        .keyboardShortcut(.cancelAction)
                    Spacer()
                    Button("Save Candidate") {
                        session.editCandidate(
                            candidate.id,
                            title: title,
                            notes: notes,
                            localPath: localPath
                        )
                        if session.errorMessage == nil { dismiss() }
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                .padding(.top, 4)
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "tray")
                        .font(.system(size: 32))
                        .foregroundStyle(.secondary)
                    Text("No candidate selected")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text("Choose a candidate from the menu bar to review and edit.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)
            }
        }
        .padding(20)
        .frame(minWidth: 440, maxWidth: 500)
        .onAppear {
            loadCandidate()
            isTitleFocused = true
        }
        .onChange(of: session.candidateEditorID) { _, _ in
            loadCandidate()
            isTitleFocused = true
        }
    }

    private func loadCandidate() {
        guard let candidate = session.candidateBeingEdited else { return }
        title = candidate.title
        notes = candidate.notes ?? ""
        localPath = candidate.localPath ?? ""
    }
}

