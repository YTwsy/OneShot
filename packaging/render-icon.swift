import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// Original vector geometry, rendered at every required iconset size. No external assets.
guard CommandLine.arguments.count == 2 else {
    fputs("Usage: render-icon.swift /path/to/OneShot.iconset\n", stderr)
    exit(64)
}
let destination = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
let names = [("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64),
             ("128x128", 128), ("128x128@2x", 256), ("256x256", 256), ("256x256@2x", 512),
             ("512x512", 512), ("512x512@2x", 1024)]
for (name, pixels) in names {
    let space = CGColorSpaceCreateDeviceRGB()
    guard let context = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8,
        bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        fatalError("Cannot create icon bitmap")
    }
    context.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
    context.addPath(CGPath(roundedRect: CGRect(x: 72, y: 72, width: 880, height: 880), cornerWidth: 200,
                          cornerHeight: 200, transform: nil))
    context.clip()
    let colors = [CGColor(srgbRed: 0.19, green: 0.49, blue: 0.99, alpha: 1),
                  CGColor(srgbRed: 0.12, green: 0.25, blue: 0.79, alpha: 1)] as CFArray
    let gradient = CGGradient(colorsSpace: space, colors: colors, locations: [0, 1])!
    context.drawLinearGradient(gradient, start: CGPoint(x: 150, y: 950), end: CGPoint(x: 850, y: 70), options: [])
    context.setStrokeColor(CGColor(gray: 1, alpha: 0.98))
    context.setLineWidth(56)
    context.setLineCap(.round)
    context.setLineJoin(.round)
    for points in [[CGPoint(x: 276, y: 422), CGPoint(x: 276, y: 670), CGPoint(x: 420, y: 670)],
                   [CGPoint(x: 604, y: 670), CGPoint(x: 748, y: 670), CGPoint(x: 748, y: 528)],
                   [CGPoint(x: 748, y: 392), CGPoint(x: 748, y: 354), CGPoint(x: 604, y: 354)],
                   [CGPoint(x: 420, y: 354), CGPoint(x: 276, y: 354), CGPoint(x: 276, y: 392)]] {
        context.beginPath(); context.move(to: points[0]); points.dropFirst().forEach { context.addLine(to: $0) }
        context.strokePath()
    }
    context.setFillColor(CGColor(gray: 1, alpha: 1))
    context.fillEllipse(in: CGRect(x: 455, y: 455, width: 114, height: 114))
    context.setFillColor(CGColor(srgbRed: 1, green: 0.70, blue: 0.24, alpha: 1))
    context.fillEllipse(in: CGRect(x: 724, y: 692, width: 92, height: 92))
    guard let image = context.makeImage(),
          let output = CGImageDestinationCreateWithURL(destination.appendingPathComponent("icon_\(name).png") as CFURL,
                                                       UTType.png.identifier as CFString, 1, nil) else {
        fatalError("Cannot create icon PNG")
    }
    CGImageDestinationAddImage(output, image, nil)
    guard CGImageDestinationFinalize(output) else { fatalError("Cannot write icon PNG") }
}
