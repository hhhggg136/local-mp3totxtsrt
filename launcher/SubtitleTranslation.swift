import Foundation

struct TranslationCue: Equatable {
    let timing: String
    let text: String
}
struct SubtitleTranslation {
    static func error(_ text: String) -> NSError {
        NSError(domain: "SubtitleTranslation", code: 1, userInfo: [NSLocalizedDescriptionKey: text])
    }
    static func load(_ url: URL) throws -> [TranslationCue] {
        guard (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) <= 5_000_000 else { throw error("字幕超过 5 MB，请分批翻译。") }
        return try parse(String(contentsOf: url, encoding: .utf8))
    }
    static func parse(_ input: String) throws -> [TranslationCue] {
        let value = input.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n").trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\u{feff}")))
        let separator = try NSRegularExpression(pattern: "\\n[ \\t]*\\n+")
        let normalized = separator.stringByReplacingMatches(in: value, range: NSRange(value.startIndex..., in: value), withTemplate: "\n\n")
        let blocks = normalized.components(separatedBy: "\n\n")
        guard !value.isEmpty, blocks.count <= 10000 else { throw error("需要有效 SRT，最多 10000 条。") }
        let pattern = try NSRegularExpression(pattern: "^(\\d{2,}):([0-5]\\d):([0-5]\\d),(\\d{3}) --> (\\d{2,}):([0-5]\\d):([0-5]\\d),(\\d{3})$")
        return try blocks.map { block in
            let lines = block.components(separatedBy: "\n")
            guard lines.count >= 3, Int(lines[0].trimmingCharacters(in: .whitespaces)) != nil else { throw error("字幕条目格式错误。") }
            let timing = lines[1].trimmingCharacters(in: .whitespaces)
            let ns = timing as NSString
            guard let match = pattern.firstMatch(in: timing, range: NSRange(location: 0, length: ns.length)) else { throw error("SRT 时间码格式错误。") }
            let n = try (1...8).map { index -> Int in
                guard let number = Int(ns.substring(with: match.range(at: index))), number < 100000 else { throw error("时间码超出范围。") }
                return number
            }
            let start = ((n[0]*60+n[1])*60+n[2])*1000+n[3]
            let end = ((n[4]*60+n[5])*60+n[6])*1000+n[7]
            let text = lines.dropFirst(2).joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            guard end > start, !text.isEmpty, text.count <= 4000 else { throw error("字幕时长或正文不符合翻译要求。") }
            return TranslationCue(timing: timing, text: text)
        }
    }
    static func render(_ cues: [TranslationCue], translated: [String], bilingual: Bool) throws -> (srt: String, txt: String) {
        guard !cues.isEmpty, cues.count == translated.count else { throw error("译文条数与原字幕不一致，未导出。") }
        var srt = "", txt = ""
        for (i, cue) in cues.enumerated() {
            // Normalize newlines to keep each translated sentence inside its own SRT block.
            let translation = translated[i].split(whereSeparator: { $0.isNewline }).joined(separator: " ").trimmingCharacters(in: .whitespaces)
            guard !translation.isEmpty else { throw error("第 \(i+1) 条译文为空，未导出。") }
            let text = bilingual ? cue.text + "\n" + translation : translation
            srt += "\(i+1)\n\(cue.timing)\n\(text)\n\n"
            txt += "[\(cue.timing)]\n\(text)\n\n"
        }
        return (srt, txt)
    }
    static func export(cues: [TranslationCue], translated: [String], beside source: URL, target: String, bilingual: Bool) throws -> URL {
        guard ["zh-Hans", "en", "es"].contains(target) else { throw error("不支持的译文语言。") }
        let translation = try render(cues, translated: translated, bilingual: false)
        let dual = bilingual ? try render(cues, translated: translated, bilingual: true) : nil
        let fm = FileManager.default
        let folder = source.deletingLastPathComponent().appendingPathComponent("翻译_\(target)_" + UUID().uuidString)
        try fm.createDirectory(at: folder, withIntermediateDirectories: false)
        do {
            try translation.srt.write(to: folder.appendingPathComponent("译文.srt"), atomically: true, encoding: .utf8)
            try translation.txt.write(to: folder.appendingPathComponent("译文.txt"), atomically: true, encoding: .utf8)
            if let dual {
                try dual.srt.write(to: folder.appendingPathComponent("双语字幕.srt"), atomically: true, encoding: .utf8)
                try dual.txt.write(to: folder.appendingPathComponent("双语对白.txt"), atomically: true, encoding: .utf8)
            }
            return folder
        } catch { try? fm.removeItem(at: folder); throw error }
    }
}
