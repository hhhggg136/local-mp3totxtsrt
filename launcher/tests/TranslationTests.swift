import Foundation
@main struct TranslationTests {
 static func main() throws {
  let original = "7\r\n00:00:01,200 --> 00:00:02,500\r\nHello\r\nworld.\r\n\r\n8\r\n00:00:08,000 --> 00:00:09,100\r\nGoodbye.\r\n"
  let cues = try SubtitleTranslation.parse(original)
  precondition(cues.count == 2 && cues[0].text == "Hello\nworld.")
  let result = try SubtitleTranslation.render(cues, translated: ["你好，世界。", "再见。"], bilingual: true)
  precondition(result.srt == "1\n00:00:01,200 --> 00:00:02,500\nHello\nworld.\n你好，世界。\n\n2\n00:00:08,000 --> 00:00:09,100\nGoodbye.\n再见。\n\n")
  let translated = try SubtitleTranslation.render(cues, translated: ["你好\n世界", "再见"], bilingual: false)
  precondition(!translated.srt.contains("Hello") && translated.srt.contains("你好 世界"))
  for bad in [[], [""], ["你好", ""]] as [[String]] {
   do { _ = try SubtitleTranslation.render(cues, translated: bad, bilingual: true); fatalError("accepted incomplete translation") } catch {}
  }
  do { _ = try SubtitleTranslation.parse("1\n00:00:02,500 --> 00:00:01,200\nwrong"); fatalError("accepted negative duration") } catch {}
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
  defer { try? FileManager.default.removeItem(at: directory) }
  let file = directory.appendingPathComponent("original.srt")
  try original.write(to: file, atomically: true, encoding: .utf8)
  let output = try SubtitleTranslation.export(cues: cues, translated: ["你好", "再见"], beside: file, target: "zh-Hans", bilingual: true)
  let saved = try String(contentsOf: file, encoding: .utf8)
  precondition(saved == original)
  let loaded = try SubtitleTranslation.load(output.appendingPathComponent("译文.srt"))
  precondition(loaded.map(\.timing) == cues.map(\.timing))
  let dual = try SubtitleTranslation.load(output.appendingPathComponent("双语字幕.srt"))
  precondition(dual.map(\.timing) == cues.map(\.timing))
  let next = try SubtitleTranslation.export(cues: cues, translated: ["你好", "再见"], beside: file, target: "zh-Hans", bilingual: false)
  precondition(next != output && !FileManager.default.fileExists(atPath: next.appendingPathComponent("双语字幕.srt").path))
  print("PASS 翻译及双语导出：时间码、停顿、多行、空译文拒绝、保留原文件、重复导出隔离")
 }
}
