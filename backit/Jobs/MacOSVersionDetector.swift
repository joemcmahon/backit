import Foundation
import IOKit

enum MacOSVersionDetector {
    static func currentBuild() -> String {
        ProcessInfo.processInfo.operatingSystemVersionString
    }

    static func hardwareUUID() -> String {
        let service = IOServiceGetMatchingService(kIOMainPortDefault,
                                                  IOServiceMatching("IOPlatformExpertDevice"))
        defer { IOObjectRelease(service) }
        guard service != 0 else { return "" }
        let uuid = IORegistryEntryCreateCFProperty(service,
                                                   "IOPlatformUUID" as CFString,
                                                   kCFAllocatorDefault, 0)
        return (uuid?.takeRetainedValue() as? String) ?? ""
    }
}
