// Renders the app icon (iOS + macOS asset catalogs): the light "Cursor" mark —
// a white pointer with a dark outline and an orange tip. Run: swift Tools/make-icon.swift .
import AppKit

let root = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : FileManager.default.currentDirectoryPath)

let paper = CGColor(red: 0xF4 / 255, green: 0xF3 / 255, blue: 0xEF / 255, alpha: 1)
let ink = CGColor(red: 0x14 / 255, green: 0x14 / 255, blue: 0x14 / 255, alpha: 1)
let tip = CGColor(red: 0xE0 / 255, green: 0x5E / 255, blue: 0x00 / 255, alpha: 1)

/// The pointer in a 100-unit box (top-left origin), tip at (38, 26).
func pointer() -> CGPath {
    let p = CGMutablePath()
    p.move(to: CGPoint(x: 38, y: 26))
    p.addLine(to: CGPoint(x: 38, y: 70))
    p.addLine(to: CGPoint(x: 48.5, y: 60))
    p.addLine(to: CGPoint(x: 56, y: 76))
    p.addLine(to: CGPoint(x: 63.5, y: 72.5))
    p.addLine(to: CGPoint(x: 56, y: 57))
    p.addLine(to: CGPoint(x: 70, y: 57))
    p.closeSubpath()
    return p
}

func render(size: Int, mac: Bool) -> Data {
    let s = CGFloat(size)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!.cgContext
    // Top-left origin, like the SVG.
    ctx.translateBy(x: 0, y: s)
    ctx.scaleBy(x: 1, y: -1)

    // macOS icons sit in a rounded square with margin and a soft shadow; iOS masks the full square.
    let body = mac ? CGRect(x: s * 0.1, y: s * 0.09, width: s * 0.8, height: s * 0.8) : CGRect(x: 0, y: 0, width: s, height: s)
    let shape = CGPath(roundedRect: body, cornerWidth: mac ? body.width * 0.225 : 0, cornerHeight: mac ? body.width * 0.225 : 0, transform: nil)
    if mac {
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: s * 0.012), blur: s * 0.03, color: CGColor(gray: 0, alpha: 0.35))
        ctx.addPath(shape); ctx.setFillColor(paper); ctx.fillPath()
        ctx.restoreGState()
    } else {
        ctx.addPath(shape); ctx.setFillColor(paper); ctx.fillPath()
    }

    // Centre the pointer (bbox 38…70 × 26…76) and scale it to the body.
    let unit = body.width / 100
    let scale: CGFloat = 1.12
    ctx.saveGState()
    ctx.translateBy(x: body.midX, y: body.midY)
    ctx.scaleBy(x: unit * scale, y: unit * scale)
    ctx.translateBy(x: -54, y: -51)
    let p = pointer()
    ctx.addPath(p); ctx.setFillColor(CGColor(gray: 1, alpha: 1)); ctx.fillPath()
    ctx.addPath(p); ctx.setStrokeColor(ink); ctx.setLineWidth(4.2); ctx.setLineJoin(.round); ctx.strokePath()
    ctx.addEllipse(in: CGRect(x: 38 - 6.5, y: 26 - 6.5, width: 13, height: 13))
    ctx.setFillColor(tip); ctx.fillPath()
    ctx.restoreGState()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

func write(_ data: Data, _ path: URL) {
    try! FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
    try! data.write(to: path)
}

// iOS: single 1024 icon.
let ios = root.appendingPathComponent("iOS/Assets.xcassets/AppIcon.appiconset")
write(render(size: 1024, mac: false), ios.appendingPathComponent("icon-1024.png"))
write("""
{ "images" : [ { "filename" : "icon-1024.png", "idiom" : "universal", "platform" : "ios", "size" : "1024x1024" } ],
  "info" : { "author" : "xcode", "version" : 1 } }
""".data(using: .utf8)!, ios.appendingPathComponent("Contents.json"))
write(#"{ "info" : { "author" : "xcode", "version" : 1 } }"#.data(using: .utf8)!, root.appendingPathComponent("iOS/Assets.xcassets/Contents.json"))

// macOS: the classic size ladder.
let mac = root.appendingPathComponent("Mac/App/Assets.xcassets/AppIcon.appiconset")
var images: [String] = []
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let px = base * scale
        let name = "mac-\(base)@\(scale)x.png"
        write(render(size: px, mac: true), mac.appendingPathComponent(name))
        images.append(#"{ "filename" : "\#(name)", "idiom" : "mac", "scale" : "\#(scale)x", "size" : "\#(base)x\#(base)" }"#)
    }
}
write("{ \"images\" : [ \(images.joined(separator: ",\n")) ], \"info\" : { \"author\" : \"xcode\", \"version\" : 1 } }".data(using: .utf8)!,
      mac.appendingPathComponent("Contents.json"))
write(#"{ "info" : { "author" : "xcode", "version" : 1 } }"#.data(using: .utf8)!, root.appendingPathComponent("Mac/App/Assets.xcassets/Contents.json"))
print("icons written")
