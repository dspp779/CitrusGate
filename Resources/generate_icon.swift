import AppKit
import Foundation

// A native replacement for generate_icon.py. PNG-backed ICNS avoids iconutil
// differences between SDK releases and keeps builds independent of NumPy/Pillow.
guard CommandLine.arguments.count == 3,
      let source = NSImage(contentsOfFile: CommandLine.arguments[1]) else {
    fputs("Usage: generate-icon source.png output.icns\n", stderr)
    exit(1)
}
func png(size: Int) -> Data {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    NSGraphicsContext.current?.imageInterpolation = .high
    let side = CGFloat(size), inner = side * 0.82, pad = (side - inner) / 2
    let path = NSBezierPath()
    for i in 0...360 {
        let angle = CGFloat(i) * .pi / 180
        let x = cos(angle), y = sin(angle)
        let point = NSPoint(x: side / 2 + inner / 2 * (x < 0 ? -1 : 1) * pow(abs(x), 0.4),
                            y: side / 2 + inner / 2 * (y < 0 ? -1 : 1) * pow(abs(y), 0.4))
        if i == 0 { path.move(to: point) } else { path.line(to: point) }
    }
    path.close(); path.addClip()
    NSColor(calibratedRed: 250/255, green: 251/255, blue: 253/255, alpha: 1).setFill()
    NSRect(x: 0, y: 0, width: side, height: side).fill()
    source.draw(in: NSRect(x: pad, y: pad, width: inner, height: inner), from: .zero,
                operation: .sourceOver, fraction: 1)
    NSGraphicsContext.restoreGraphicsState()
    return bitmap.representation(using: .png, properties: [:])!
}
func uint32(_ n: Int) -> Data {
    var value = UInt32(n).bigEndian
    return withUnsafeBytes(of: &value) { Data($0) }
}
var chunks = Data()
for (type, size) in [("icp4",16),("icp5",32),("icp6",64),("ic07",128),("ic08",256),("ic09",512),("ic10",1024)] {
    let data = png(size: size)
    chunks.append(Data(type.utf8)); chunks.append(uint32(data.count + 8)); chunks.append(data)
}
var output = Data("icns".utf8); output.append(uint32(chunks.count + 8)); output.append(chunks)
try output.write(to: URL(fileURLWithPath: CommandLine.arguments[2]), options: .atomic)
