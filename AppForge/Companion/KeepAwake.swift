import Foundation
import IOKit.pwr_mgt

/// Verhindert, dass der Mac einschläft, solange das iPhone ihn erreichen soll.
/// Hinweis: Ein zugeklapptes MacBook ohne externen Monitor schläft trotzdem ein.
@MainActor
final class KeepAwake {
    private var assertionID: IOPMAssertionID = 0
    private var active = false

    func set(_ enabled: Bool) {
        if enabled == active { return }
        if enabled {
            let reason = "AppForge: für das iPhone erreichbar bleiben" as CFString
            active = IOPMAssertionCreateWithName(
                kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn), reason, &assertionID
            ) == kIOReturnSuccess
        } else {
            IOPMAssertionRelease(assertionID)
            active = false
        }
    }
}
