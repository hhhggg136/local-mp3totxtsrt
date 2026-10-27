import Foundation
@main struct EditorFixtureProject {
    static func main() async throws {
        guard CommandLine.arguments.count == 4 else { throw EditorError.message("usage: editor-fixture-project media subtitle destination.tingting") }
        let source = try await EditorMedia.inspect(URL(fileURLWithPath: CommandLine.arguments[1]).standardizedFileURL)
        let subtitle = try String(contentsOfFile: CommandLine.arguments[2], encoding: .utf8)
        let project = try AudioEditProject.make(source: source, subtitle: subtitle)
        try AudioProjectFile.save(project, to: URL(fileURLWithPath: CommandLine.arguments[3]))
        print("Saved fixture: \(project.clips.count) clips, \(EditorClock.seconds(source.durationTicks)) seconds")
    }
}
