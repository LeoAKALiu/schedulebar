import ScheduleBar
import SwiftUI

struct CandidateEditView: View {
    @ObservedObject var session: AppSession
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var notes = ""
    @State private var localPath = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let candidate = session.candidateBeingEdited {
                TextField("Title", text: $title)
                TextField("Notes", text: $notes)
                TextField("Local path", text: $localPath)
                HStack {
                    Button("Cancel") { dismiss() }
                    Spacer()
                    Button("Save") {
                        session.editCandidate(
                            candidate.id,
                            title: title,
                            notes: notes,
                            localPath: localPath
                        )
                        if session.errorMessage == nil { dismiss() }
                    }
                    .keyboardShortcut(.defaultAction)
                }
            } else {
                Text("Choose a candidate from the menu.")
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
        .frame(width: 420)
        .onAppear(perform: loadCandidate)
        .onChange(of: session.candidateEditorID) { _, _ in loadCandidate() }
    }

    private func loadCandidate() {
        guard let candidate = session.candidateBeingEdited else { return }
        title = candidate.title
        notes = candidate.notes ?? ""
        localPath = candidate.localPath ?? ""
    }
}
