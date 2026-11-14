import Foundation
import Testing
@testable import HarborCore

@Suite struct ShellIntegrationTests {
    @Test func parsesOSC7() {
        let none: (String) -> Bool = { _ in false }
        #expect(ShellIntegration.directory(fromOSC7: "file://mac.local/Users/me/a%20b", exists: none) == "/Users/me/a b")
        #expect(ShellIntegration.directory(fromOSC7: "file:///tmp/", exists: none) == "/tmp")
        #expect(ShellIntegration.directory(fromOSC7: "file://h/%E4%B8%AD", exists: none) == "/中")
        // 没编码的原始路径里恰好有 %：解码后的路径不存在、原样存在时用原样
        #expect(ShellIntegration.directory(fromOSC7: "file://h/x%41", exists: { $0 == "/x%41" }) == "/x%41")
        #expect(ShellIntegration.directory(fromOSC7: "file://hostonly", exists: none) == nil)
        #expect(ShellIntegration.directory(fromOSC7: "relative", exists: none) == nil)
    }

    @Test func quoting() {
        #expect(ShellIntegration.quote("/usr/local/bin") == "/usr/local/bin")
        #expect(ShellIntegration.quote("/a b") == "'/a b'")
        #expect(ShellIntegration.quote("/it's") == #"'/it'\''s'"#)
        #expect(ShellIntegration.quote("/中文") == "'/中文'")
        // 控制字符不能原样进终端：^U 会清行、回车会执行
        #expect(ShellIntegration.quote("/a\u{15}rm x\r") == #"$'/a\x15rm x\x0d'"#)
        #expect(ShellIntegration.quote("/q'\\\u{1b}") == #"$'/q\'\\\x1b'"#)
        // fish：单引号里 \\ 和 \' 是转义，控制字符放在引号外
        #expect(ShellIntegration.quote("/it's\\x", style: .fish) == #"'/it\'s\\x'"#)
        #expect(ShellIntegration.quote("/a\u{15}b", style: .fish) == #"'/a'\u0015'b'"#)
        #expect(ShellIntegration.quote("/a\r", style: .fish) == #"'/a'\u000d"#)
        #expect(ShellIntegration.quote("/a b", style: .conservative) == "'/a b'")
        #expect(ShellIntegration.quote("/it's", style: .conservative) == nil)
        #expect(ShellIntegration.quote("/a!b", style: .conservative) == nil)
        #expect(ShellIntegration.quoteStyle(ofShell: "/opt/homebrew/bin/fish") == .fish)
        #expect(ShellIntegration.quoteStyle(ofShell: "/bin/tcsh") == .conservative)
    }

    @Test func localHost() {
        let names: Set<String> = ["zydeMacBook-Pro.local", "zydeMacBook-Pro"]
        #expect(ShellIntegration.isLocalHost("", localNames: names))
        #expect(ShellIntegration.isLocalHost("localhost", localNames: names))
        #expect(ShellIntegration.isLocalHost("zydemacbook-pro", localNames: names))
        #expect(!ShellIntegration.isLocalHost("build-server", localNames: names))
        #expect(ShellIntegration.host(fromOSC7: "file://box/tmp") == "box")
        #expect(ShellIntegration.host(fromOSC7: "file:///tmp") == "")
    }

    @Test func shellKind() {
        #expect(ShellIntegration.kind(ofShell: "/bin/zsh") == .zsh)
        #expect(ShellIntegration.kind(ofShell: "/opt/homebrew/bin/bash") == .bash)
        #expect(ShellIntegration.kind(ofShell: "/opt/homebrew/bin/fish") == .unsupported)
    }

    /// 真的跑一遍 zsh / bash：用户配置被加载、编码函数结果正确
    @Test(arguments: ["zsh", "bash"]) func scriptsRunInRealShell(shell: String) throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "harbor-shell-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let integration = root.appending(path: "integration", directoryHint: .isDirectory)
        let home = root.appending(path: "home", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try ShellIntegration.install(in: integration)
        // 假的用户配置，确认会被加载
        try Data("USER_RC=loaded\n".utf8).write(to: home.appending(path: shell == "zsh" ? ".zshrc" : ".bash_profile"))

        let launch = ShellIntegration.launch(shell: "/bin/\(shell)", directory: integration,
                                             cdFile: root.appending(path: "cd"), session: "tok123",
                                             environment: ["HOME": home.path(percentEncoded: false), "PATH": "/usr/bin:/bin"])
        let process = Process()
        process.executableURL = URL(filePath: "/bin/\(shell)")
        let probe = #"_harbor_urlencode "/a b/中%"; print_it() { printf '%s|%s|%s|%s\n' "$USER_RC" "$REPLY" "$HARBOR_SESSION:$(/usr/bin/env | /usr/bin/grep -c HARBOR_SESSION)" "${HISTFILE:t}:${HISTFILE:h:t}"; }; print_it"#
        // zsh 用 -i 让它读 .zshrc；bash 用 --rcfile 加 -i
        process.arguments = shell == "zsh" ? ["-i", "-c", probe] : launch.args.filter { $0 != "-i" } + ["-i", "-c", probe]
        process.environment = launch.environment
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let fields = text.split(separator: "\n").last?.split(separator: "|", omittingEmptySubsequences: false).map(String.init) ?? []
        #expect(fields.prefix(2) == ["loaded", "/a%20b/%E4%B8%AD%25"])
        // 令牌在 shell 里有，但子进程（env）看不到
        #expect(fields.count > 2 && fields[2] == "tok123:0")
        if shell == "zsh" {
            // HISTFILE 在用户的主目录（假 home），不在 Harbor 的 integration/zsh 下
            #expect(fields.last == ".zsh_history:home")
        }
    }
}
