// Prints the cursor position (used by the Bluetooth end-to-end test).
import CoreGraphics
let p = CGEvent(source: nil)!.location
print(Int(p.x), Int(p.y))
