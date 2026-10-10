import AppKit
let folder = CommandLine.arguments[1]
try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
for size in [16,32,128,256,512] {
 for scale in [1,2] {
  let pixels = size * scale
  let image = NSImage(size: NSSize(width: pixels, height: pixels))
  image.lockFocus()
  NSColor(calibratedRed: 0.12, green: 0.27, blue: 0.42, alpha: 1).setFill()
  NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: pixels, height: pixels), xRadius: CGFloat(pixels) * 0.22, yRadius: CGFloat(pixels) * 0.22).fill()
  let symbol = NSImage(systemSymbolName: "waveform", accessibilityDescription: nil)!.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: CGFloat(pixels) * 0.6, weight: .medium))!.withSymbolConfiguration(NSImage.SymbolConfiguration(paletteColors: [.white]))!
  let rect = NSRect(x: CGFloat(pixels) * 0.16, y: CGFloat(pixels) * 0.24, width: CGFloat(pixels) * 0.68, height: CGFloat(pixels) * 0.52)
  symbol.draw(in: rect)
  image.unlockFocus()
  let bitmap = NSBitmapImageRep(data: image.tiffRepresentation!)!
  try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: folder + "/icon_\(size)x\(size)\(scale == 2 ? "@2x" : "").png"))
 }
}
