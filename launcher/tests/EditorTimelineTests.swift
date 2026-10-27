import Foundation

@main struct EditorTimelineTests {
    static func main() throws {
        func t(_ seconds: Int64) -> Int64 { seconds * 48_000 }
        var checks = 0
        func check(_ condition: Bool, _ name: String) {
            guard condition else { fputs("FAIL \(name)\n", stderr); exit(1) }
            checks += 1; print("PASS \(name)")
        }
        let subtitle = "1\n00:00:01,000 --> 00:00:02,000\n第一段\n\n2\n00:00:05,000 --> 00:00:06,000\n第二段\n\n3\n00:00:09,000 --> 00:00:10,000\n第三段\n"
        let source = EditorSource(path: "/fixture.wav", durationTicks: t(12), fileSize: 1, sha256: String(repeating: "0", count: 64))
        let project = try AudioEditProject.make(source: source, subtitle: subtitle)
        let editor = try AudioEditHistory(project: project)
        let a = project.clips[0].id, b = project.clips[1].id, c = project.clips[2].id
        check(project.clips.map(\.initial) == [TickRange(start: 0, end: 168000), TickRange(start: 168000, end: 360000), TickRange(start: 360000, end: 576000)], "默认片段覆盖开头、句间和结尾声音")
        check(project.timeline(.original).duration == t(12), "原始时间线完整且独立")
        editor.move(c, to: 0)
        let moved = editor.project.projected(editor.project.timeline(.edited))
        check(moved.map(\.text) == ["第三段", "第一段", "第二段"], "重排对白顺序")
        check(moved.map(\.timeline) == [TickRange(start:72000,end:120000),TickRange(start:264000,end:312000),TickRange(start:456000,end:504000)], "重排字幕使用同一片段映射并保留停顿")
        editor.setDeleted(b, true)
        var map = editor.project.timeline(.edited)
        check(map.duration == t(8) && map.entries.map(\.clipID) == [c,a], "删除只排除引用区间")
        check(map.sourceTime(at: 0) == 360000 && map.sourceTime(at: 216000) == 0 && map.sourceTime(at: map.duration) == nil, "游标与源区间采用左闭右开映射")
        check(map.timelineTime(source:t(5),clipID:b) == nil, "已删除片段不映射到剪辑播放")
        check(editor.project.projected(editor.project.timeline(.original)).map(\.timeline) == [TickRange(start:t(1),end:t(2)),TickRange(start:t(5),end:t(6)),TickRange(start:t(9),end:t(10))], "编辑不改变原始时间码")
        try editor.trim(c,to:TickRange(start:456000,end:576000))
        map=editor.project.timeline(.edited)
        let cut=editor.project.projected(map)
        check(cut[0].timeline == TickRange(start:0,end:24000) && cut[0].needsTextReview && cut[0].text == "第三段", "剪入半句保留文字并标记核对")
        check(editor.project.previewRange(clipID:c,map:map) == TickRange(start:0,end:24000), "裁剪后的试听仅覆盖剩余对白")
        editor.confirmReview(c,confirmed:true)
        check(!editor.project.projected(map)[0].needsTextReview, "人工核对状态可确认")
        editor.undo();editor.undo()
        check(editor.project.clips.first(where:{$0.id==c})?.range == TickRange(start:360000,end:576000), "撤销还原边界")
        editor.undo()
        check(editor.project.timeline(.edited).duration == t(12), "撤销还原删除")
        editor.undo()
        check(editor.project.order == project.order, "撤销还原顺序")
        editor.redo();editor.redo()
        let rendered = try editor.project.subtitles(map:editor.project.timeline(.edited))
        check(rendered.srt == "1\n00:00:01,500 --> 00:00:02,500\n第三段\n\n2\n00:00:05,500 --> 00:00:06,500\n第一段\n\n", "SRT 实际导出时码与顺序")
        let originalDialogue=project.dialogues[0].id
        try editor.editText(originalDialogue,text:"第一段已校对")
        check(!editor.canRedo && editor.project.dialogues[0].text == "第一段已校对", "新编辑清空重做，文字独立保存")
        do { try editor.trim(a,to:TickRange(start:0,end:t(9))); check(false,"拒绝越界裁剪") } catch { check(true,"拒绝越界裁剪") }
        for index in 0..<100 { try editor.editText(originalDialogue,text:"编辑\(index)") }
        check(editor.historyCount == 50, "撤销记录有上限且只存编辑命令")
        let temp=FileManager.default.temporaryDirectory.appendingPathComponent("editor-tests-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:temp,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:temp) }
        let file=temp.appendingPathComponent("project.tingting")
        try AudioProjectFile.save(editor.project,to:file)
        let first=try AudioProjectFile.load(file)
        editor.setDeleted(a,true)
        try AudioProjectFile.save(editor.project,to:file)
        let saved=try AudioProjectFile.load(file),backup=try AudioProjectFile.load(file.appendingPathExtension("bak"))
        check(saved==editor.project && backup==first,"项目保存重开与上一份完整备份")
        var protects=saved;protects.source.path=file.path
        do { try AudioProjectFile.save(protects,to:file);check(false,"拒绝覆盖原素材路径") } catch { check(true,"拒绝覆盖原素材路径") }
        let link=temp.appendingPathComponent("source-link.tingting")
        try FileManager.default.createSymbolicLink(at:link,withDestinationURL:file)
        do { try AudioProjectFile.save(protects,to:link);check(false,"拒绝通过软链接覆盖原素材") } catch { check(true,"拒绝通过软链接覆盖原素材") }
        let reopened=try AudioEditHistory(project:saved)
        check(!reopened.canUndo && !reopened.canRedo,"重开项目不重放历史")
        var invalid=saved;invalid.order=[a,a,a]
        do { try invalid.validate();check(false,"拒绝损坏顺序") } catch { check(true,"拒绝损坏顺序") }
        let overlap="1\n00:00:01,000 --> 00:00:03,000\n甲\n\n2\n00:00:02,000 --> 00:00:04,000\n乙\n\n3\n00:00:04,500 --> 00:00:05,000\n丙\n"
        let grouped=try AudioEditProject.make(source:source,subtitle:overlap)
        check(grouped.clips.count==2 && grouped.clips[0].dialogueIDs.count==2,"重叠对白保持同一块，不擅自拆开说话")
        let noDialogue=try AudioEditProject.make(source:source,subtitle:nil)
        check(noDialogue.clips.count==1 && noDialogue.timeline(.edited).duration==t(12),"无对白仍保留完整音频编辑能力")
        check(try EditorClock.parseSeconds("9.500") == 456000,"数值边界按整数毫秒解析")
        var bilingual = project
        bilingual.dialogues[0].text = "第一段\nFirst line"
        let bilingualSRT = try bilingual.subtitles(map: bilingual.timeline(.edited)).srt
        check(bilingualSRT.contains("第一段\nFirst line\n\n"), "剪辑保留双语字幕的两行布局")
        print("\(checks) editor core checks passed")
    }
}
