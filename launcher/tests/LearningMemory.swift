import Foundation
import Darwin

@main struct LearningMemory {
 static func main() throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent("learning-memory-" + UUID().uuidString)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: directory) }
  if CommandLine.arguments.contains("--baseline") { print("baseline"); return }
  let store = try LearningStore(url: directory.appendingPathComponent("learning.sqlite"))
  func resident() -> UInt64 {
   var info = mach_task_basic_info()
   var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
   let result = withUnsafeMutablePointer(to: &info) { pointer in
    pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count) }
   }
   return result == KERN_SUCCESS ? UInt64(info.resident_size) : 0
  }
  let before = resident()
  var samples: [UInt64] = []
  for pass in 0..<20 {
   try autoreleasepool {
    var original = "", corrected = ""
    for i in 0..<5000 {
     let hour = i / 3600, minute = i / 60 % 60, second = i % 60
     let range = String(format: "%02d:%02d:%02d,000 --> %02d:%02d:%02d,900", hour, minute, second, hour, minute, second)
     original += "\(i+1)\n\(range)\n旧甲\(i)甲\n\n"
     corrected += "\(i+1)\n\(range)\n新乙\(i)乙\n\n"
    }
    // Vary only the SRT entry numbering to exercise distinct receipt transactions without growing the term set.
    original = original.replacingOccurrences(of: "1\n00:00:00", with: "\(pass+10000)\n00:00:00")
    _ = try store.importPair(original: original, corrected: corrected, project: "压力测试")
    let entries = try store.entries(project: "压力测试")
    if pass == 0 { for row in entries { try store.approve(id: row.id, enabled: true) } }
    let prompt = try store.prompt(project: "压力测试")
    guard !prompt.isEmpty, prompt.count <= 410 else { fatalError("prompt not bounded") }
   }
   samples.append(resident())
  }
  let rows = try store.entries(project: "压力测试", limit: 5000)
  guard rows.count == 5000, rows.allSatisfy({ $0.count == 20 }) else { fatalError("storage cap/update failure") }
  var usage = rusage(); getrusage(RUSAGE_SELF, &usage)
  let data: [String: Any] = ["fixture": "synthetic SRT, 5000 terms, 20 distinct correction imports", "before_bytes": before, "after_each_import_bytes": samples, "peak_rss_bytes": usage.ru_maxrss, "database_bytes": try directory.appendingPathComponent("learning.sqlite").resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0, "rules": rows.count]
  print(String(data: try JSONSerialization.data(withJSONObject: data, options: [.prettyPrinted, .sortedKeys]), encoding: .utf8)!)
 }
}
