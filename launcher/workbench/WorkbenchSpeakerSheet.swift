import SwiftUI

struct WorkbenchSpeakerSheet: View {
    @ObservedObject var model: AudioWorkbenchModel
    @Environment(\.dismiss) private var dismiss
    @State private var expected = 0
    @State private var names: [String: String] = [:]
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("本地说话人区分").font(.title2.bold())
            Text("仅区分当前素材中的声音，不判断真实身份，不跨视频记人。短句、变声、游戏角色配音或多人同时说话可能分错。")
                .font(.callout).foregroundColor(.secondary)
            HStack {
                Picker("预计人数", selection: $expected) {
                    Text("自动估计").tag(0)
                    ForEach(1...8, id: \.self) { Text("\($0) 人").tag($0) }
                }.frame(width: 240)
                Spacer()
                Button("本地分析说话人") { model.analyzeSpeakers(expected: expected) }
                    .disabled(model.project?.dialogues.isEmpty != false || model.busy)
            }
            Text("按原字幕逐句分析，每句最多取 3 个短窗口。疑似混合、过短或不确定时保留待确认。分析完成会替换已有分人结果并清空撤销历史；不会改写文字或音频剪辑。")
                .font(.caption).foregroundColor(.secondary)
            Divider()
            HStack {
                Text("项目内说话人 · 改名会更新所有关联对白").font(.headline)
                Spacer()
                Button("新增说话人", action: model.addSpeaker).disabled((model.project?.speakerData?.speakers.count ?? 0) >= 26)
            }
            ScrollView {
                VStack(spacing: 10) {
                    ForEach(model.project?.speakerData?.speakers ?? []) { speaker in
                        HStack {
                            Text(speaker.id).font(.headline).frame(width: 30)
                            TextField("名字", text: Binding(get: { names[speaker.id] ?? speaker.name }, set: { names[speaker.id] = $0 })).textFieldStyle(.roundedBorder)
                            Button("保存名字") { model.renameSpeaker(speaker.id, name: names[speaker.id] ?? speaker.name) }
                        }
                    }
                    if model.project?.speakerData?.speakers.isEmpty != false { Text("可以先分析，也可以新增 A/B/C 后逐句指定。").foregroundColor(.secondary) }
                }
            }.frame(minHeight: 70, maxHeight: 220)
            Text("单句纠正：关闭此窗口，选中对白，在右侧“这句说话人”中更改。名字和单句归属支持撤销，并随 .tingting 项目保存；导出时可选择是否带名字。")
                .font(.caption).foregroundColor(.secondary)
            if let metrics = model.speakerMetrics { Text(metrics).font(.caption).foregroundColor(.secondary) }
            HStack { Text(model.status).font(.caption).lineLimit(2); Spacer(); Button("完成") { dismiss() } }
        }.padding(24).frame(width: 660)
    }
}
