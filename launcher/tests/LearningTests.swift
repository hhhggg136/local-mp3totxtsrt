import Foundation

@main struct LearningTests {
 static func main() throws {
  let temp = FileManager.default.temporaryDirectory.appendingPathComponent("learning-tests-" + UUID().uuidString)
  try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: temp) }
  let store = try LearningStore(url: temp.appendingPathComponent("learning.sqlite"))
  let original = "1\n00:00:01,000 --> 00:00:03,000\n欢迎来到星河块跑\n\n2\n00:00:04,000 --> 00:00:06,000\n嗯我们开始吧\n"
  let corrected = "1\n00:00:01,000 --> 00:00:03,000\n欢迎来到星河快跑\n\n2\n00:00:04,000 --> 00:00:06,000\n我们开始吧\n"
  var failures = 0
  func check(_ condition: Bool, _ name: String) { print("\(condition ? "PASS" : "FAIL") \(name)"); if !condition { failures += 1 } }
  let first = try store.importPair(original: original, corrected: corrected, project: "作品A")
  let entries = try store.entries(project: "作品A")
  check(first.learned == 1 && entries.count == 1, "记录替换但不把删语气词作为词语纠错")
  check(try store.prompt(project: "作品A").isEmpty, "未经确认的词不能进入识别提示")
  if let item = entries.first {
   try store.approve(id: item.id, enabled: true)
   check(try store.prompt(project: "作品A").contains("快跑"), "确认后使用正确词提示")
   check(try store.prompt(project: "作品B").isEmpty, "不同项目的词库隔离")
   _ = try store.importPair(original: original, corrected: corrected, project: "作品A")
   check(try store.entries(project: "作品A").first?.count == 1, "同一校对版本重复导入不重复计数")
   try store.edit(id: item.id, right: "快跑计划")
   check(try store.entries(project: "作品A").first?.right == "快跑计划", "人工编辑词语持久保存")
   check(try store.prompt(project: "作品A").isEmpty, "编辑词语后需要重新确认")
   try store.approve(id: item.id, enabled: false)
   check(try store.prompt(project: "作品A").isEmpty, "停用词语立即停止提供提示")
   try store.delete(id: item.id)
   check(try store.entries(project: "作品A").isEmpty, "删除词语后不再显示")
  }
  do { _ = try store.importPair(original: "不是字幕", corrected: corrected, project: "A"); check(false, "拒绝无效字幕") } catch { check(true, "拒绝无效字幕") }
  let shifted = corrected.replacingOccurrences(of: "00:00:01,000", with: "00:00:01,500")
  let skipped = try store.importPair(original: original, corrected: shifted, project: "移动时间码")
  check(skipped.learned == 0 && skipped.unmatched > 0, "不从无法可靠对应的时间码误学")
  let duplicate = original + "\n3\n00:00:01,000 --> 00:00:03,000\n另外一句\n"
  check(try store.importPair(original: duplicate, corrected: corrected, project: "重复区间").learned == 0, "歧义重复时间区间不参与学习")
  let quote = "作品 ' 特殊字符"
  _ = try store.importPair(original: original, corrected: corrected, project: quote)
  check(try store.entries(project: quote).count == 1, "项目名特殊字符安全存储")
  let reopened = try LearningStore(url: temp.appendingPathComponent("learning.sqlite"))
  check(try reopened.entries(project: quote).count == 1, "关闭重开后保留学习库")
  check(LearningStore.suggestScene("LibTV AI 视频生成模型") == "AI 视频制作", "场景只给出候选建议")
  if failures > 0 { exit(1) }
 }
}
