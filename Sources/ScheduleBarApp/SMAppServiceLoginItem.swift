import Foundation
import ScheduleBar
import ServiceManagement

final class SMAppServiceLoginItem: LoginItemControlling, @unchecked Sendable {
    var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    func setEnabled(_ enabled: Bool) {
        if enabled {
            try? SMAppService.mainApp.register()
        } else {
            try? SMAppService.mainApp.unregister()
        }
    }
}
