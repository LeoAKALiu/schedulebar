import AppKit
import SwiftUI

struct MenuBarView: View {
    @ObservedObject var session: AppSession
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        if session.state.menuTasks.isEmpty {
            Text("No tasks yet")
        } else {
            ForEach(session.state.menuTasks) { task in
                Text(task.title)
            }
        }
        Divider()
        Button("Quick Add…") {
            openWindow(id: "quick-add")
        }
        Button("Open Console") {
            openWindow(id: "console")
        }
        Divider()
        Button("Quit ScheduleBar") {
            NSApplication.shared.terminate(nil)
        }
    }
}
