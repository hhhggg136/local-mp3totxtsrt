import Foundation
import SQLite3
import CryptoKit

struct LearningEntry: Identifiable {
    var id: Int64
    var wrong: String
    var right: String
    var count: Int
    var enabled: Bool
}
struct ImportSummary { var learned: Int; var unmatched: Int; var duplicate: Bool }
private struct Cue { var start: Int; var end: Int; var text: String; var key: String { "\(start):\(end)" } }

final class LearningStore {
    private var db: OpaquePointer?
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    static var defaultURL: URL {
        if let directory = ProcessInfo.processInfo.environment["LOCAL_SUBTITLE_DATA_DIR"] {
            return URL(fileURLWithPath: directory).appendingPathComponent("learning.sqlite")
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LocalSubtitleTool/learning.sqlite")
    }
    init(url: URL) throws {
        let parent = url.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: parent.path) {
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else { throw Self.error("无法打开本地学习库。") }
        do {
            sqlite3_busy_timeout(db, 3000)
            try execute("PRAGMA cache_size=-1024")
            try execute("CREATE TABLE IF NOT EXISTS rules(id INTEGER PRIMARY KEY, project TEXT NOT NULL, wrong TEXT NOT NULL, right TEXT NOT NULL, count INTEGER NOT NULL DEFAULT 1, enabled INTEGER NOT NULL DEFAULT 0, UNIQUE(project,wrong,right))")
            try execute("CREATE TABLE IF NOT EXISTS imports(fingerprint TEXT PRIMARY KEY)")
            try execute("CREATE INDEX IF NOT EXISTS rules_project ON rules(project,enabled,count)")
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch { sqlite3_close(db); db = nil; throw error }
    }
    deinit { sqlite3_close(db) }
    private static func error(_ text: String) -> NSError { NSError(domain: "Learning", code: 1, userInfo: [NSLocalizedDescriptionKey: text]) }
    private func statement(_ sql: String, _ arguments: [String]) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw Self.error("学习库查询失败。") }
        for (index, value) in arguments.enumerated() { sqlite3_bind_text(statement, Int32(index + 1), value, -1, transient) }
        return statement
    }
    private func execute(_ sql: String, _ arguments: [String] = []) throws {
        let query = try statement(sql, arguments); defer { sqlite3_finalize(query) }
        guard sqlite3_step(query) == SQLITE_DONE else { throw Self.error("学习库写入失败，原有记录已保留。") }
    }
    private static func projectKey(_ name: String) throws -> String {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines).precomposedStringWithCanonicalMapping
        guard !name.isEmpty, name.count <= 80 else { throw error("请输入 1–80 个字的项目名称。") }
        return name
    }
    private static func parse(_ text: String) throws -> [Cue] {
        guard text.utf8.count <= 5_000_000 else { throw error("单份字幕最多支持 5 MB，请分批导入。") }
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n").trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\u{feff}")))
        let blocks = normalized.components(separatedBy: "\n\n").filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard !blocks.isEmpty, blocks.count <= 10_000 else { throw error("请输入有效的 SRT 字幕，最多 10000 条。") }
        let regex = try NSRegularExpression(pattern: "^(\\d{2,}):(\\d{2}):(\\d{2})[,\\.](\\d{3})$")
        func time(_ value: String) throws -> Int {
            let value = value.trimmingCharacters(in: .whitespaces)
            let ns = value as NSString
            guard let match = regex.firstMatch(in: value, range: NSRange(location: 0, length: ns.length)) else { throw error("字幕时间码格式不正确。") }
            let numbers = (1...4).map { Int(ns.substring(with: match.range(at: $0))) ?? -1 }
            guard numbers[0] >= 0, numbers[0] < 10000, numbers[1] < 60, numbers[2] < 60 else { throw error("字幕时间码超出范围。") }
            return ((numbers[0] * 60 + numbers[1]) * 60 + numbers[2]) * 1000 + numbers[3]
        }
        return try blocks.map { block in
            let lines = block.components(separatedBy: "\n")
            guard lines.count >= 3, Int(lines[0].trimmingCharacters(in: .whitespaces)) != nil else { throw error("无法读取 SRT 条目，请保留序号、时间码和正文。") }
            let range = lines[1].components(separatedBy: "-->")
            guard range.count == 2 else { throw error("字幕缺少起止时间码。") }
            let start = try time(range[0]), end = try time(range[1])
            let content = lines.dropFirst(2).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            guard end > start, !content.isEmpty, content.count <= 1000 else { throw error("字幕时长或正文不符合导入要求。") }
            return Cue(start: start, end: end, text: content)
        }
    }
    private static func correction(_ original: String, _ corrected: String) -> (String, String)? {
        let a = Array(original), b = Array(corrected)
        var prefix = 0
        while prefix < min(a.count, b.count), a[prefix] == b[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < min(a.count, b.count) - prefix, a[a.count-1-suffix] == b[b.count-1-suffix] { suffix += 1 }
        let wrong = Array(a[prefix..<(a.count-suffix)]), right = Array(b[prefix..<(b.count-suffix)])
        func word(_ chars: [Character]) -> Bool { !chars.isEmpty && chars.count <= 8 && chars.allSatisfy { $0.isLetter || $0.isNumber } }
        guard word(wrong), word(right), wrong != right else { return nil }
        // Keep a small amount of shared context so a one-character correction becomes a useful term.
        let left = Array(a[..<prefix].suffix(2).reversed().prefix { $0.isLetter || $0.isNumber }.reversed())
        let tail = Array(a[(a.count-suffix)...].prefix(2).prefix { $0.isLetter || $0.isNumber })
        return (String(left + wrong + tail), String(left + right + tail))
    }
    func importPair(original: String, corrected: String, project: String) throws -> ImportSummary {
        let project = try Self.projectKey(project)
        let before = try Self.parse(original), after = try Self.parse(corrected)
        func hash(_ value: String) -> String { SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined() }
        let fingerprint = hash(project + ":" + hash(original) + ":" + hash(corrected))
        let query = try statement("SELECT 1 FROM imports WHERE fingerprint=?", [fingerprint])
        let exists = sqlite3_step(query) == SQLITE_ROW; sqlite3_finalize(query)
        if exists { return ImportSummary(learned: 0, unmatched: 0, duplicate: true) }
        let originalGroups = Dictionary(grouping: before, by: \.key)
        let correctedGroups = Dictionary(grouping: after, by: \.key)
        var learned = 0, unmatched = 0
        try execute("BEGIN IMMEDIATE")
        do {
            for row in after {
                guard let matches = originalGroups[row.key], matches.count == 1, correctedGroups[row.key]?.count == 1 else { unmatched += 1; continue }
                guard let pair = Self.correction(matches[0].text, row.text) else { continue }
                try execute("INSERT INTO rules(project,wrong,right) SELECT ?,?,? WHERE (SELECT COUNT(*) FROM rules WHERE project=?)<5000 OR EXISTS(SELECT 1 FROM rules WHERE project=? AND wrong=? AND right=?) ON CONFLICT(project,wrong,right) DO UPDATE SET count=count+1", [project, pair.0, pair.1, project, project, pair.0, pair.1])
                if sqlite3_changes(db) > 0 { learned += 1 }
            }
            try execute("INSERT INTO imports(fingerprint) VALUES(?)", [fingerprint])
            try execute("COMMIT")
        } catch { try? execute("ROLLBACK"); throw error }
        return ImportSummary(learned: learned, unmatched: unmatched, duplicate: false)
    }
    func entries(project: String, limit: Int = 200) throws -> [LearningEntry] {
        let query = try statement("SELECT id,wrong,right,count,enabled FROM rules WHERE project=? ORDER BY count DESC,id DESC LIMIT ?", [try Self.projectKey(project), String(max(1, min(limit, 5000)))])
        defer { sqlite3_finalize(query) }
        var result: [LearningEntry] = []
        while true {
            let status = sqlite3_step(query)
            if status == SQLITE_DONE { break }
            guard status == SQLITE_ROW else { throw Self.error("无法读取学习记录。") }
            result.append(LearningEntry(id: sqlite3_column_int64(query, 0), wrong: String(cString: sqlite3_column_text(query, 1)), right: String(cString: sqlite3_column_text(query, 2)), count: Int(sqlite3_column_int(query, 3)), enabled: sqlite3_column_int(query, 4) != 0))
        }
        return result
    }
    func prompt(project: String) throws -> String {
        let query = try statement("SELECT DISTINCT right FROM rules WHERE project=? AND enabled=1 ORDER BY count DESC LIMIT 32", [try Self.projectKey(project)])
        defer { sqlite3_finalize(query) }
        var words: [String] = []
        while sqlite3_step(query) == SQLITE_ROW {
            let word = String(cString: sqlite3_column_text(query, 0))
            if (words.joined(separator: "、") + "、" + word).count <= 400 { words.append(word) }
        }
        return words.isEmpty ? "" : "相关词语：" + words.joined(separator: "、") + "。"
    }
    func approve(id: Int64, enabled: Bool) throws { try execute("UPDATE rules SET enabled=? WHERE id=?", [enabled ? "1" : "0", String(id)]) }
    func edit(id: Int64, right: String) throws {
        let value = right.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.count <= 32, !value.contains("\n"), !value.contains("\u{fffd}") else { throw Self.error("正确词语应为 1–32 个字，不能包含换行或乱码。") }
        try execute("UPDATE rules SET right=?, enabled=0 WHERE id=?", [value, String(id)])
    }
    func delete(id: Int64) throws { try execute("DELETE FROM rules WHERE id=?", [String(id)]) }
    static func suggestScene(_ text: String) -> String? {
        let lower = text.lowercased()
        let categories = [("AI 视频制作", ["libtv", "aigc", "seedance", "视频生成", "转绘"]), ("电商", ["sku", "代发", "退款", "电商", "拼多多"]), ("影视对白", ["剧本", "旁白", "分镜", "短剧"])]
        return categories.first { $0.1.contains { lower.contains($0) } }?.0
    }
    static func readSubtitle(_ url: URL) throws -> String {
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= 5_000_000 else { throw error("单份字幕最多支持 5 MB，请分批导入。") }
        return try String(contentsOf: url, encoding: .utf8)
    }
}
