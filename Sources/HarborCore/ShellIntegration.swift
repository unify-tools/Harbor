import Foundation

/// 内嵌终端的 shell integration（做法和 VS Code 类似，不改用户自己的配置文件）：
/// - 每次显示提示符时用 OSC 7 报告当前目录，浏览区据此跟随
/// - 绑定一个特殊按键序列（cdKeySequence）到「静默 cd」：从 HARBOR_CD_FILE 读目标目录，
///   在行编辑器里直接切换并重画提示符，不在终端里留下 cd 命令，也不清掉用户输入到一半的内容
///
/// zsh：把 ZDOTDIR 指到 Harbor 的目录，那里的 .zshenv / .zprofile / .zshrc / .zlogin 先加载用户原来的同名文件。
/// bash：用 --rcfile 启动，先按登录 shell 的顺序加载用户配置。其他 shell 不注入，只是不能同步目录。
public enum ShellIntegration {
    public enum Kind: Sendable, Equatable {
        case zsh, bash, unsupported
    }

    /// 触发静默 cd 的按键序列（不会和真实按键冲突的私有 CSI 序列）
    public static let cdKeySequence = "\u{1b}[5555~"

    public static func kind(ofShell path: String) -> Kind {
        switch (path as NSString).lastPathComponent {
        case "zsh": .zsh
        case "bash": .bash
        default: .unsupported
        }
    }

    /// 把脚本写到 directory 下（每次启动覆盖，保证和程序版本一致）
    public static func install(in directory: URL) throws {
        let fm = FileManager.default
        let zdotdir = directory.appending(path: "zsh", directoryHint: .isDirectory)
        try fm.createDirectory(at: zdotdir, withIntermediateDirectories: true)
        let files: [(URL, String)] = [
            (zdotdir.appending(path: ".zshenv"), zshenv),
            (zdotdir.appending(path: ".zprofile"), zprofile),
            (zdotdir.appending(path: ".zshrc"), zshrc),
            (zdotdir.appending(path: ".zlogin"), zlogin),
            (directory.appending(path: "harbor.zsh"), harborZsh),
            (directory.appending(path: "harbor.bash"), harborBash),
        ]
        for (url, content) in files {
            try Data(content.utf8).write(to: url, options: .atomic)
        }
    }

    /// 启动参数和要追加的环境变量。directory 是 install 的目录，cdFile 是静默 cd 读取目标的文件
    /// session 是本次终端的随机令牌：集成脚本报告目录时把它放在 OSC 7 的主机名位置，
    /// 并且取消 export（子进程拿不到），这样命令输出、文件内容、ssh 远端都伪造不了目录报告
    public static func launch(shell: String, directory: URL, cdFile: URL, session: String, environment: [String: String])
        -> (args: [String], execName: String, environment: [String: String]) {
        var env = environment
        env["HARBOR_CD_FILE"] = cdFile.path(percentEncoded: false)
        env["HARBOR_SESSION"] = session
        let name = (shell as NSString).lastPathComponent
        switch kind(ofShell: shell) {
        case .zsh:
            // 用户原来的 ZDOTDIR（没设就是主目录），在我们的 .zshenv 里恢复
            env["HARBOR_USER_ZDOTDIR"] = environment["ZDOTDIR"] ?? environment["HOME"] ?? NSHomeDirectory()
            env["ZDOTDIR"] = directory.appending(path: "zsh").path(percentEncoded: false)
            // argv[0] 以 - 开头 = 登录 shell，和 Terminal.app 一样
            return ([], "-" + name, env)
        case .bash:
            return (["--rcfile", directory.appending(path: "harbor.bash").path(percentEncoded: false), "-i"], name, env)
        case .unsupported:
            return ([], "-" + name, env)
        }
    }

    /// 解析 OSC 7 的内容：file://主机/路径（路径按 URL 规则百分号编码）。
    /// 有的程序发的是没编码的原始路径，解码后不存在时就按原样用。
    public static func directory(fromOSC7 text: String, exists: (String) -> Bool = { path in
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
    }) -> String? {
        var rest = Substring(text)
        if rest.hasPrefix("file://") {
            rest = rest.dropFirst("file://".count)
            // 跳过主机名
            guard let slash = rest.firstIndex(of: "/") else { return nil }
            rest = rest[slash...]
        }
        let raw = String(rest)
        guard raw.hasPrefix("/") else { return nil }
        if let decoded = raw.removingPercentEncoding, decoded != raw {
            if exists(decoded) || !exists(raw) { return normalized(decoded) }
        }
        return normalized(raw)
    }

    /// 插入路径时的引号规则，按 shell 选
    public enum QuoteStyle: Sendable, Equatable {
        /// sh 系：'…' 里没有转义，单引号写成 '\''
        case posix
        /// fish：'…' 里 \\ 和 \' 是转义
        case fish
        /// 不认识的 shell（tcsh、nu、xonsh…）：只接受各家单引号都按字面处理的名字
        case conservative
    }

    public static func quoteStyle(ofShell path: String) -> QuoteStyle {
        switch (path as NSString).lastPathComponent {
        case "zsh", "bash", "sh", "dash", "ksh", "mksh": .posix
        case "fish": .fish
        default: .conservative
        }
    }

    private static let safeCharacters = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789/._-+,:@%")

    private static func isControl(_ scalar: Unicode.Scalar) -> Bool {
        scalar.value < 0x20 || (0x7F...0x9F).contains(scalar.value)
    }

    /// 粘贴、拖进终端的路径：只含安全字符时原样，否则按 shell 的规则加引号。
    /// 含控制字符（APFS 允许文件名里有 ^U、回车）时写成转义，
    /// 否则这些字符原样进终端会被行编辑器当成按键，文件名就能注入命令。
    /// 没法安全表示时返回 nil（调用方不插入）
    public static func quote(_ path: String, style: QuoteStyle = .posix) -> String? {
        if !path.isEmpty, path.unicodeScalars.allSatisfy(safeCharacters.contains) { return path }
        let hasControl = path.unicodeScalars.contains(where: isControl)
        switch style {
        case .posix:
            guard hasControl else {
                return "'" + path.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
            }
            var result = "$'"
            for scalar in path.unicodeScalars {
                switch scalar {
                case "\\": result += #"\\"#
                case "'": result += #"\'"#
                default:
                    if isControl(scalar) {
                        for byte in String(scalar).utf8 { result += String(format: "\\x%02x", byte) }
                    } else {
                        result.unicodeScalars.append(scalar)
                    }
                }
            }
            return result + "'"
        case .fish:
            // 控制字符放在引号外，用 \uXXXX
            var result = "'"
            var quoted = true
            for scalar in path.unicodeScalars {
                if isControl(scalar) {
                    if quoted { result += "'"; quoted = false }
                    result += String(format: "\\u%04x", scalar.value)
                    continue
                }
                if !quoted { result += "'"; quoted = true }
                switch scalar {
                case "\\": result += #"\\"#
                case "'": result += #"\'"#
                default: result.unicodeScalars.append(scalar)
                }
            }
            return quoted ? result + "'" : result
        case .conservative:
            let risky = CharacterSet(charactersIn: "'\\!")
            guard !hasControl, !path.unicodeScalars.contains(where: risky.contains) else { return nil }
            return "'" + path + "'"
        }
    }

    /// OSC 7 里的主机名是不是本机。ssh 到别的机器后，远端 shell 报告的目录不能拿来跳转
    public static func isLocalHost(_ host: String, localNames: Set<String>) -> Bool {
        let name = host.lowercased()
        if name.isEmpty || name == "localhost" { return true }
        let short = name.hasSuffix(".local") ? String(name.dropLast(".local".count)) : name
        return localNames.contains { candidate in
            let local = candidate.lowercased()
            return local == name || local == short || local.hasPrefix(short + ".")
        }
    }

    /// 拆出 OSC 7 的主机名；不是 file:// 形式时为空
    public static func host(fromOSC7 text: String) -> String {
        guard text.hasPrefix("file://") else { return "" }
        let rest = text.dropFirst("file://".count)
        return String(rest.prefix { $0 != "/" })
    }

    private static func normalized(_ path: String) -> String {
        URL(filePath: path).pathKey
    }

    // MARK: - 脚本

    static let zshenv = """
    # Harbor：先加载用户自己的 .zshenv，再把 ZDOTDIR 指回 Harbor，让 zsh 接着读这里的其余文件
    HARBOR_ZDOTDIR=$ZDOTDIR
    ZDOTDIR=$HARBOR_USER_ZDOTDIR
    [[ -f $ZDOTDIR/.zshenv ]] && source $ZDOTDIR/.zshenv
    # 用户的 .zshenv 可能改了 ZDOTDIR，以它为准
    HARBOR_USER_ZDOTDIR=$ZDOTDIR
    ZDOTDIR=$HARBOR_ZDOTDIR

    """

    static let zprofile = """
    ZDOTDIR=$HARBOR_USER_ZDOTDIR
    [[ -f $ZDOTDIR/.zprofile ]] && source $ZDOTDIR/.zprofile
    ZDOTDIR=$HARBOR_ZDOTDIR

    """

    static let zshrc = """
    # /etc/zshrc 在这之前按当时的 ZDOTDIR（Harbor 的目录）设了 HISTFILE，改回用户的位置，和 Terminal.app 共用历史
    [[ $HISTFILE == $HARBOR_ZDOTDIR/.zsh_history ]] && HISTFILE=$HARBOR_USER_ZDOTDIR/.zsh_history
    ZDOTDIR=$HARBOR_USER_ZDOTDIR
    [[ -f $ZDOTDIR/.zshrc ]] && source $ZDOTDIR/.zshrc
    source "${HARBOR_ZDOTDIR:h}/harbor.zsh"
    ZDOTDIR=$HARBOR_ZDOTDIR

    """

    static let zlogin = """
    ZDOTDIR=$HARBOR_USER_ZDOTDIR
    [[ -f $ZDOTDIR/.zlogin ]] && source $ZDOTDIR/.zlogin
    # 之后在终端里再开的 zsh 按用户自己的配置走
    if [[ $ZDOTDIR == $HOME ]]; then unset ZDOTDIR; fi
    unset HARBOR_ZDOTDIR HARBOR_USER_ZDOTDIR

    """

    static let harborZsh = #"""
    # Harbor 终端的 shell integration：报告当前目录（OSC 7），提供静默 cd 的按键
    [[ -o interactive ]] || return 0

    # 按字节做 URL 百分号编码，结果放在 REPLY
    _harbor_urlencode() {
      emulate -L zsh
      local LC_ALL=C str=$1 c i
      REPLY=
      for (( i = 1; i <= ${#str}; i++ )); do
        c=$str[i]
        case $c in
          [a-zA-Z0-9/._~-]) REPLY+=$c ;;
          *) REPLY+=%${(l:2::0:)$(( [##16] #c & 255 ))} ;;
        esac
      done
    }

    # 会话令牌只留在这个 shell 里，不传给子进程
    typeset -g +x HARBOR_SESSION

    _harbor_report_cwd() {
      local ret=$?
      _harbor_urlencode "$PWD"
      printf '\e]7;file://%s%s\a' "${HARBOR_SESSION:-$HOST}" "$REPLY"
      return $ret
    }

    autoload -Uz add-zsh-hook
    add-zsh-hook precmd _harbor_report_cwd

    _harbor_cd() {
      local target f
      [[ -r $HARBOR_CD_FILE ]] || return 0
      target=$(<$HARBOR_CD_FILE)
      # 读完就删：Harbor 看到文件一直没被取走，就知道集成失效了（比如 exec 了别的 shell），不再发按键
      command rm -f -- $HARBOR_CD_FILE
      if [[ ! -d $target || $target == $PWD ]]; then
        _harbor_report_cwd
        return 0
      fi
      # 钩子（chpwd 里的 auto-ls、direnv）可能要输出，先让 zle 腾出屏幕
      zle -I
      builtin cd -- "$target" || { _harbor_report_cwd; return 0; }
      # 重算提示符（主题、git 状态）并报告目录，然后重画当前行，用户输入到一半的内容保留
      (( $+functions[precmd] )) && precmd
      for f in $precmd_functions; do "$f"; done
      zle reset-prompt
    }
    zle -N _harbor_cd
    bindkey -M emacs '\e[5555~' _harbor_cd
    bindkey -M viins '\e[5555~' _harbor_cd
    bindkey -M vicmd '\e[5555~' _harbor_cd

    # 调试脚本（HARBOR_SCRIPT）跑的命令不写进用户的历史
    if [[ -n $HARBOR_NO_HISTORY ]]; then unset HISTFILE HARBOR_NO_HISTORY; fi

    """#

    static let harborBash = #"""
    # Harbor 终端的 shell integration（bash）。用 --rcfile 启动，先按登录 shell 的顺序加载系统和用户配置
    # /etc/profile 跑 path_helper，从图形界面启动时 PATH 才完整
    [ -f /etc/profile ] && . /etc/profile
    if [ -f ~/.bash_profile ]; then . ~/.bash_profile
    elif [ -f ~/.bash_login ]; then . ~/.bash_login
    elif [ -f ~/.profile ]; then . ~/.profile
    fi

    _harbor_urlencode() {
      local LC_ALL=C str=$1 c i n h
      REPLY=
      for (( i = 0; i < ${#str}; i++ )); do
        c=${str:i:1}
        case $c in
          [a-zA-Z0-9/._~-]) REPLY+=$c ;;
          *) printf -v n '%d' "'$c"; printf -v h '%02X' $(( n & 255 )); REPLY+=%$h ;;
        esac
      done
    }

    # 保留 $?，后面的 PROMPT_COMMAND（starship、__git_ps1）还要用它显示上条命令是否失败
    # 会话令牌只留在这个 shell 里，不传给子进程
    export -n HARBOR_SESSION

    _harbor_report_cwd() {
      local ret=$?
      _harbor_urlencode "$PWD"
      printf '\e]7;file://%s%s\a' "${HARBOR_SESSION:-$HOSTNAME}" "$REPLY"
      return $ret
    }
    PROMPT_COMMAND="_harbor_report_cwd${PROMPT_COMMAND:+; $PROMPT_COMMAND}"

    # bash 没法在 bind -x 里重画提示符，切换后提示符里的目录要到下一行才更新
    _harbor_cd() {
      local target
      [ -r "$HARBOR_CD_FILE" ] || return 0
      target=$(<"$HARBOR_CD_FILE")
      command rm -f -- "$HARBOR_CD_FILE"
      if [ -d "$target" ] && [ "$target" != "$PWD" ]; then builtin cd -- "$target"; fi
      _harbor_report_cwd
    }
    bind -m emacs -x '"\e[5555~": _harbor_cd'
    bind -m vi-insert -x '"\e[5555~": _harbor_cd'
    bind -m vi-command -x '"\e[5555~": _harbor_cd'

    if [ -n "$HARBOR_NO_HISTORY" ]; then unset HISTFILE HARBOR_NO_HISTORY; fi

    """#
}
