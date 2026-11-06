// Listen-only: prints raw HID input reports from the iPhone's Bluetooth LE HID device.
// Usage: hidlisten [seconds]
import Foundation
import IOKit.hid
let m = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
IOHIDManagerSetDeviceMatching(m, [kIOHIDTransportKey: "Bluetooth Low Energy", kIOHIDProductKey: "iPhone"] as CFDictionary)
let cb: IOHIDReportCallback = { _, _, _, type, id, report, len in
    let bytes = (0..<len).map { String(format: "%02x", report[$0]) }.joined(separator: " ")
    print("report id=\(id) type=\(type.rawValue) [\(bytes)]")
    fflush(stdout)
}
IOHIDManagerScheduleWithRunLoop(m, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
let r = IOHIDManagerOpen(m, IOOptionBits(kIOHIDOptionsTypeNone))
print("open:", String(format: "0x%x", r), "access:", IOHIDCheckAccess(kIOHIDRequestTypeListenEvent).rawValue)
if let devs = IOHIDManagerCopyDevices(m) as? Set<IOHIDDevice> {
    for d in devs {
        let usage = IOHIDDeviceGetProperty(d, kIOHIDPrimaryUsageKey as CFString) as? Int ?? -1
        print("device usage", usage, IOHIDDeviceGetProperty(d, kIOHIDMaxInputReportSizeKey as CFString) ?? "")
        let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: 64)
        IOHIDDeviceRegisterInputReportCallback(d, buf, 64, cb, nil)
    }
}
RunLoop.main.run(until: Date().addingTimeInterval(Double(CommandLine.arguments.dropFirst().first ?? "60")!))
