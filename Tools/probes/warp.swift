// Moves the cursor to x y (test setup only).
import CoreGraphics
import Foundation
let a = CommandLine.arguments
CGWarpMouseCursorPosition(CGPoint(x: Double(a[1])!, y: Double(a[2])!))
