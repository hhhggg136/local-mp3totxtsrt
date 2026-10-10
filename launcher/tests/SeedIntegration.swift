import Foundation
@main struct SeedIntegration {
 static func main() throws {
  let store = try LearningStore(url: LearningStore.defaultURL)
  let original = "1\n00:00:01,000 --> 00:00:03,000\n欢迎来到星河块跑\n"
  let corrected = "1\n00:00:01,000 --> 00:00:03,000\n欢迎来到星河快跑\n"
  _ = try store.importPair(original: original, corrected: corrected, project: "默认项目")
  for entry in try store.entries(project: "默认项目") { try store.approve(id: entry.id, enabled: true) }
  print(try store.prompt(project: "默认项目"))
 }
}
