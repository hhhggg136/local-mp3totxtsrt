import AppKit
let folder = CommandLine.arguments[1]
let sourceURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("assets/listening-mascot-a2.png")
guard let source = NSImage(contentsOf: sourceURL) else {
    fatalError("无法读取应用图标原图：\(sourceURL.path)")
}
try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
for size in [16,32,128,256,512] {
 for scale in [1,2] {
  let pixels = size * scale
  let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
      bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
      colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
  NSGraphicsContext.saveGraphicsState()
  NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
  let rect = NSRect(x: 0, y: 0, width: pixels, height: pixels)
  NSBezierPath(roundedRect: rect, xRadius: CGFloat(pixels) * 0.22, yRadius: CGFloat(pixels) * 0.22).addClip()
  NSGraphicsContext.current?.imageInterpolation = .high
  source.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
  NSGraphicsContext.restoreGraphicsState()
  try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: folder + "/icon_\(size)x\(size)\(scale == 2 ? "@2x" : "").png"))
 }
}
