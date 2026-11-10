// Draws the app icon and writes it as an .iconset folder.
//
//     swift scripts/make-icon.swift <output.iconset>
//
// `iconutil -c icns <output.iconset>` then turns that into AppIcon.icns.
// The build script runs both steps, so the icon never needs to be checked in.

import AppKit

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write(Data("usage: make-icon.swift <output.iconset>\n".utf8))
    exit(64)
}
let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

/// Draws the icon into a square context `side` pixels across, on a 1024-unit canvas.
func drawIcon(in context: CGContext, side: CGFloat) {
    context.scaleBy(x: side / 1024, y: side / 1024)
    let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
        CGColor(colorSpace: colorSpace, components: [r, g, b, a])!
    }

    // The standard macOS icon shape, with a blue-to-violet gradient.
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let shape = CGPath(roundedRect: body, cornerWidth: 186, cornerHeight: 186, transform: nil)
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: color(0, 0, 0, 0.32))
    context.addPath(shape)
    context.setFillColor(color(0.25, 0.40, 0.92))
    context.fillPath()
    context.restoreGState()
    context.saveGState()
    context.addPath(shape)
    context.clip()
    let gradient = CGGradient(colorsSpace: colorSpace,
                              colors: [color(0.33, 0.62, 1.0), color(0.42, 0.30, 0.90)] as CFArray, locations: [0, 1])!
    context.drawLinearGradient(gradient, start: CGPoint(x: 512, y: body.maxY), end: CGPoint(x: 512, y: body.minY), options: [])
    context.restoreGState()

    // Two stacked photos, the back one tilted.
    func photo(center: CGPoint, angle: CGFloat, alpha: CGFloat) {
        context.saveGState()
        context.translateBy(x: center.x, y: center.y)
        context.rotate(by: angle)
        let card = CGRect(x: -230, y: -175, width: 460, height: 350)
        context.setShadow(offset: CGSize(width: 0, height: -8), blur: 18, color: color(0, 0, 0, 0.25))
        context.addPath(CGPath(roundedRect: card, cornerWidth: 26, cornerHeight: 26, transform: nil))
        context.setFillColor(color(1, 1, 1, alpha))
        context.fillPath()
        context.setShadow(offset: .zero, blur: 0, color: nil)
        // The picture inside the white border: sky, sun, hills.
        let picture = card.insetBy(dx: 26, dy: 26)
        context.addPath(CGPath(roundedRect: picture, cornerWidth: 12, cornerHeight: 12, transform: nil))
        context.clip()
        let sky = CGGradient(colorsSpace: colorSpace, colors: [color(0.55, 0.80, 1.0), color(0.85, 0.93, 1.0)] as CFArray, locations: [0, 1])!
        context.drawLinearGradient(sky, start: CGPoint(x: 0, y: picture.maxY), end: CGPoint(x: 0, y: picture.minY), options: [])
        context.setFillColor(color(1.0, 0.80, 0.25))
        context.fillEllipse(in: CGRect(x: 70, y: 40, width: 80, height: 80))
        context.setFillColor(color(0.20, 0.66, 0.45))
        context.move(to: CGPoint(x: picture.minX, y: picture.minY))
        context.addLine(to: CGPoint(x: picture.minX, y: -40))
        context.addLine(to: CGPoint(x: -90, y: 60))
        context.addLine(to: CGPoint(x: 20, y: -30))
        context.addLine(to: CGPoint(x: 110, y: 20))
        context.addLine(to: CGPoint(x: picture.maxX, y: -70))
        context.addLine(to: CGPoint(x: picture.maxX, y: picture.minY))
        context.closePath()
        context.fillPath()
        context.restoreGState()
    }
    photo(center: CGPoint(x: 480, y: 560), angle: 0.12, alpha: 0.75)
    photo(center: CGPoint(x: 512, y: 520), angle: -0.05, alpha: 1)

    // A sync badge in the bottom-right corner: two arrows chasing round a circle.
    let badge = CGPoint(x: 720, y: 300)
    context.setFillColor(color(1, 1, 1))
    context.setShadow(offset: CGSize(width: 0, height: -6), blur: 14, color: color(0, 0, 0, 0.3))
    context.fillEllipse(in: CGRect(x: badge.x - 130, y: badge.y - 130, width: 260, height: 260))
    context.setShadow(offset: .zero, blur: 0, color: nil)
    let arrowColor = color(0.30, 0.42, 0.95)
    context.setStrokeColor(arrowColor)
    context.setFillColor(arrowColor)
    context.setLineWidth(30)
    context.setLineCap(.round)
    let radius: CGFloat = 72
    for start in [CGFloat.pi * 0.15, CGFloat.pi * 1.15] {
        let end = start + .pi * 0.62
        context.addArc(center: badge, radius: radius, startAngle: start, endAngle: end, clockwise: false)
        context.strokePath()
        // Arrowhead at the end of the arc, pointing along it.
        let tip = CGPoint(x: badge.x + radius * cos(end + 0.28), y: badge.y + radius * sin(end + 0.28))
        let back = end - 0.05
        let outer = CGPoint(x: badge.x + (radius + 34) * cos(back), y: badge.y + (radius + 34) * sin(back))
        let inner = CGPoint(x: badge.x + (radius - 34) * cos(back), y: badge.y + (radius - 34) * sin(back))
        context.move(to: tip)
        context.addLine(to: outer)
        context.addLine(to: inner)
        context.closePath()
        context.fillPath()
    }
}

func writePNG(side: Int, name: String) throws {
    let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    guard let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { throw CocoaError(.fileWriteUnknown) }
    context.interpolationQuality = .high
    drawIcon(in: context, side: CGFloat(side))
    guard let image = context.makeImage(),
          let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    else { throw CocoaError(.fileWriteUnknown) }
    try data.write(to: output.appendingPathComponent(name))
}

for points in [16, 32, 128, 256, 512] {
    try writePNG(side: points, name: "icon_\(points)x\(points).png")
    try writePNG(side: points * 2, name: "icon_\(points)x\(points)@2x.png")
}
