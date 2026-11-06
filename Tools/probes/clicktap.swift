// Listen-only: logs every mouse down/up the window server sees, with position and how long it was held.
// Usage: clicktap [seconds]
import CoreGraphics
import Foundation
let mask = (1 << CGEventType.leftMouseDown.rawValue) | (1 << CGEventType.leftMouseUp.rawValue)
var lastDown: Double = 0
let tap = CGEvent.tapCreate(tap: .cghidEventTap, place: .headInsertEventTap, options: .listenOnly, eventsOfInterest: CGEventMask(mask), callback: { _, type, e, _ in
    let t = Double(e.timestamp) / 1e9
    let p = e.location
    if type == .leftMouseDown { lastDown = t; print(String(format: "DOWN at %.0f,%.0f clicks=%d", p.x, p.y, e.getIntegerValueField(.mouseEventClickState))) }
    else { print(String(format: "UP   at %.0f,%.0f held %.0f ms", p.x, p.y, (t - lastDown) * 1000)) }
    fflush(stdout)
    return Unmanaged.passUnretained(e)
}, userInfo: nil)
if let tap { CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(nil, tap, 0), .commonModes); CGEvent.tapEnable(tap: tap, enable: true) }
RunLoop.main.run(until: Date().addingTimeInterval(Double(CommandLine.arguments.dropFirst().first ?? "60")!))
