import Foundation
import Translation
import NaturalLanguage
import CryptoKit

// Real system translation, never a mock. Requires installed language packs.
// Writes only synthetic fixtures and their real translated outputs to a new directory.
@available(macOS 26.0, *)
@main struct TranslationIntegration {
    static func main() async throws {
        guard [2,4].contains(CommandLine.arguments.count) else {
            throw SubtitleTranslation.error("Usage: translation-integration output-parent [source target]")
        }
        let root = URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent("real-translation-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let fixtures: [(String, [String])] = [
            ("zh-Hans", ["你好，欢迎使用字幕工具。", "请保留原来的时间码。", "谢谢，明天见。"]),
            ("en", ["Hello, welcome to the subtitle tool.", "Please keep the original time codes.", "Thank you. See you tomorrow."]),
            ("es", ["Hola, bienvenidos a la herramienta de subtítulos.", "Por favor, conserva los códigos de tiempo originales.", "Muchas gracias. Hasta mañana."])
        ]
        let times = ["00:00:01,000 --> 00:00:02,500", "00:00:07,000 --> 00:00:08,500", "00:00:12,300 --> 00:00:14,800"]
        var reports: [[String: Any]] = []
        for (sourceCode, original) in fixtures {
            if CommandLine.arguments.count == 4, sourceCode != CommandLine.arguments[2] { continue }
            let source = root.appendingPathComponent(sourceCode + ".srt")
            let cues = zip(times, original).map { TranslationCue(timing: $0.0, text: $0.1) }
            let text = try SubtitleTranslation.render(cues, translated: original, bilingual: false).srt
            try text.write(to: source, atomically: true, encoding: .utf8)
            let digest = SHA256.hash(data: try Data(contentsOf: source))
            for (targetCode, _) in fixtures where targetCode != sourceCode {
                if CommandLine.arguments.count == 4, targetCode != CommandLine.arguments[3] { continue }
                let from = Locale.Language(identifier: sourceCode), to = Locale.Language(identifier: targetCode)
                guard await LanguageAvailability().status(from: from, to: to) == .installed else {
                    throw SubtitleTranslation.error("Language pack not installed: \(sourceCode) -> \(targetCode)")
                }
                let session = TranslationSession(installedSource: from, target: to)
                var translated: [String] = []
                for sentence in original { translated.append(try await session.translate(sentence).targetText) }
                guard translated.count == 3, translated.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }), translated != original else {
                    throw SubtitleTranslation.error("Translation returned empty or unchanged fixture")
                }
                let detected = NLLanguageRecognizer.dominantLanguage(for: translated.joined(separator: " "))?.rawValue ?? "unknown"
                let expected = targetCode == "zh-Hans" ? "zh-Hans" : targetCode
                guard detected == expected else { throw SubtitleTranslation.error("Unexpected language: \(detected), wanted \(expected)") }
                for bilingual in [false, true] {
                    let folder = try SubtitleTranslation.export(cues: cues, translated: translated, beside: source, target: targetCode, bilingual: bilingual)
                    let translatedCues = try SubtitleTranslation.load(folder.appendingPathComponent("译文.srt"))
                    guard translatedCues.map(\.timing) == times, translatedCues.count == 3 else { throw SubtitleTranslation.error("Translated timeline changed") }
                    if bilingual {
                        let dual = try SubtitleTranslation.load(folder.appendingPathComponent("双语字幕.srt"))
                        guard dual.map(\.timing) == times else { throw SubtitleTranslation.error("Bilingual timeline changed") }
                        for index in 0..<3 {
                            guard dual[index].text == original[index] + "\n" + translated[index].split(whereSeparator: { $0.isNewline }).joined(separator: " ").trimmingCharacters(in: .whitespaces) else {
                                throw SubtitleTranslation.error("Original/translation ordering changed")
                            }
                        }
                    } else if FileManager.default.fileExists(atPath: folder.appendingPathComponent("双语字幕.srt").path) {
                        throw SubtitleTranslation.error("Unexpected bilingual output when disabled")
                    }
                    guard SHA256.hash(data: try Data(contentsOf: source)) == digest else { throw SubtitleTranslation.error("Original subtitle changed") }
                    reports.append(["source": sourceCode, "target": targetCode, "bilingual": bilingual, "translation": translated, "detectedTargetLanguage": detected, "cueCount": translatedCues.count, "timestampsUnchanged": true, "originalUnchanged": true, "output": folder.lastPathComponent])
                }
                print("PASS real system translation: \(sourceCode) -> \(targetCode); both output modes")
            }
        }
        guard !reports.isEmpty else { throw SubtitleTranslation.error("No language pair was tested") }
        let report: [String: Any] = ["passed": true, "engine": "Apple Translation installed language packs", "syntheticTextOnly": true, "cases": reports]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: root.appendingPathComponent("report.json"), options: .atomic)
        print("REPORT=" + root.appendingPathComponent("report.json").path)
    }
}
