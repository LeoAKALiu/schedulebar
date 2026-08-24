import SwiftUI

struct QuickAddView: View {
    @ObservedObject var session: AppSession
    @Environment(\.dismiss) private var dismiss

    @State private var title = ""
    @State private var notes = ""
    @State private var localPath = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Quick Add")
                .font(.headline)
            TextField("Title", text: $title)
            TextField("Notes (optional)", text: $notes, axis: .vertical)
                .lineLimit(3...6)
            TextField("Local path (optional)", text: $localPath)
            if let errorMessage = session.errorMessage {
                Text(errorMessage)
                    .foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Add") {
                    session.quickAdd(title: title, notes: notes, localPath: localPath)
                    if session.errorMessage == nil {
                        title = ""
                        notes = ""
                        localPath = ""
                        dismiss()
                    }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding()
        .frame(minWidth: 360)
    }
}
