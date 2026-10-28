import Foundation

struct ProjectSpeaker: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var name: String
    var title: String { name == id ? id : id + " · " + name }
}
struct SpeakerAssignment: Codable, Equatable, Sendable {
    var speakerID: String?
    var manual: Bool
    var note: String
}
struct SpeakerProjectData: Codable, Equatable, Sendable {
    var speakers: [ProjectSpeaker] = []
    var assignments: [UUID: SpeakerAssignment] = [:]
    var model = "manual"
    func label(_ dialogue: UUID) -> String {
        guard let id = assignments[dialogue]?.speakerID else { return "待确认" }
        return speakers.first { $0.id == id }?.name ?? "待确认"
    }
    func validate(dialogues: Set<UUID>) throws {
        let ids = Set(speakers.map(\.id))
        guard speakers.count <= 26, ids.count == speakers.count,
              speakers.allSatisfy({ Self.codes.contains($0.id) && Self.validName($0.name) }),
              assignments.count <= dialogues.count,
              assignments.allSatisfy({ dialogues.contains($0.key) && ($0.value.speakerID == nil || ids.contains($0.value.speakerID!)) && $0.value.note.count <= 200 }),
              model.count <= 200 else { throw EditorError.message("说话人数据不正确。") }
    }
    static let codes = (65...90).map { String(UnicodeScalar($0)!) }
    static func validName(_ value: String) -> Bool {
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && value.count <= 40 &&
        !value.contains(where: { $0.isNewline || $0 == ":" || $0 == "：" || $0.isASCII && $0.asciiValue! < 32 })
    }
}

// Only transient, normalized vectors; never written into the project or learning DB.
struct SpeakerVector: Sendable {
    var dialogue: UUID
    var values: [Float]
}
enum SpeakerClustering {
    static func normalized(_ values: [Float]) -> [Float]? {
        guard !values.isEmpty, values.allSatisfy(\.isFinite) else { return nil }
        let norm = sqrt(values.reduce(Float(0)) { $0 + $1 * $1 })
        guard norm.isFinite, norm > 0.000001 else { return nil }
        return values.map { $0 / norm }
    }
    static func cosine(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count else { return -1 }
        return zip(a, b).reduce(0) { $0 + $1.0 * $1.1 }
    }
    static func group(dialogues: [EditorDialogue], vectors: [SpeakerVector], expected: Int = 0) throws -> SpeakerProjectData {
        guard (0...8).contains(expected) else { throw EditorError.message("说话人数须为自动或 1–8 人。") }
        let known = Set(dialogues.map(\.id))
        guard vectors.count <= dialogues.count * 3, vectors.allSatisfy({ known.contains($0.dialogue) && $0.values.count == 192 }) else {
            throw EditorError.message("说话人模型输出与字幕不匹配。")
        }
        let windows = Dictionary(grouping: vectors, by: \.dialogue)
        var features: [UUID: [Float]] = [:]
        var notes: [UUID: String] = [:]
        for dialogue in dialogues {
            let values = (windows[dialogue.id] ?? []).compactMap { normalized($0.values) }
            guard let first = values.first else { notes[dialogue.id] = "声音过短、过轻或无法分析"; continue }
            // Disagreement across a cue is not evidence that its whole text is one speaker.
            guard values.allSatisfy({ cosine(first, $0) >= 0.45 }) else {
                notes[dialogue.id] = "同一句声音变化较大，可能有多人或干扰"; continue
            }
            let sum = values.reduce([Float](repeating: 0, count: first.count)) { a, b in zip(a, b).map(+) }
            features[dialogue.id] = normalized(sum)
        }
        let usable = dialogues.filter { features[$0.id] != nil }.sorted {
            $0.range.duration == $1.range.duration ? $0.range.start < $1.range.start : $0.range.duration > $1.range.duration
        }
        var centers: [[Float]] = [], counts: [Int] = []
        if expected > 0, let first = usable.first {
            centers = [features[first.id]!]
            while centers.count < min(expected, usable.count) {
                let next = usable.max { a, b in
                    centers.map { cosine(features[a.id]!, $0) }.max()! > centers.map { cosine(features[b.id]!, $0) }.max()!
                }!
                let value = features[next.id]!
                guard centers.map({ cosine(value, $0) }).max()! < 0.99999 else { break }
                centers.append(value)
            }
            for _ in 0..<12 {
                try Task.checkCancellation()
                var sums = centers.map { _ in [Float](repeating: 0, count: 192) }; counts = centers.map { _ in 0 }
                for item in usable {
                    let v = features[item.id]!, k = centers.indices.max { cosine(v, centers[$0]) < cosine(v, centers[$1]) }!
                    sums[k] = zip(sums[k], v).map(+); counts[k] += 1
                }
                centers = centers.indices.map { normalized(sums[$0]) ?? centers[$0] }
            }
        } else {
            for item in usable {
                try Task.checkCancellation()
                let value = features[item.id]!
                if let k = centers.indices.max(by: { cosine(value, centers[$0]) < cosine(value, centers[$1]) }), cosine(value, centers[k]) >= 0.55 {
                    centers[k] = normalized(zip(centers[k].map { $0 * Float(counts[k]) }, value).map(+))!; counts[k] += 1
                } else if centers.count < 26 { centers.append(value); counts.append(1) }
            }
        }
        var labels: [UUID: Int] = [:]
        for item in usable {
            let value = features[item.id]!
            let ranking = centers.indices.sorted { cosine(value, centers[$0]) > cosine(value, centers[$1]) }
            guard let best = ranking.first else { continue }
            let score = cosine(value, centers[best])
            let margin = ranking.count > 1 ? score - cosine(value, centers[ranking[1]]) : 1
            if score >= 0.45 && margin >= 0.06 { labels[item.id] = best }
            else { notes[item.id] = "声音相似或干扰较大，无法可靠区分" }
        }
        // Name by first appearance in source, independent of edit order or seed order.
        var codes: [Int: String] = [:]
        var result = SpeakerProjectData(model: "sherpa-onnx-2.0.1/campplus-zh-en-v1")
        for dialogue in dialogues.sorted(by: { $0.range.start < $1.range.start }) {
            if let cluster = labels[dialogue.id] {
                if codes[cluster] == nil {
                    let code = SpeakerProjectData.codes[codes.count]; codes[cluster] = code
                    result.speakers.append(ProjectSpeaker(id: code, name: code))
                }
                result.assignments[dialogue.id] = SpeakerAssignment(speakerID: codes[cluster], manual: false, note: "自动结果，请试听核对")
            } else {
                result.assignments[dialogue.id] = SpeakerAssignment(speakerID: nil, manual: false, note: notes[dialogue.id] ?? "待确认")
            }
        }
        try result.validate(dialogues: known)
        return result
    }
}
