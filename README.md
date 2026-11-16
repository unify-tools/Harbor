# Harbor

macOS 文件管理器，Swift + AppKit，最低 macOS 26。

## 常用命令

```sh
scripts/bundle.sh            # 编译并生成 build/Harbor.app（release）
scripts/bundle.sh debug      # debug 版
scripts/release.sh           # 发布到 GitHub Releases（见下面「发布」）
scripts/release.sh --local   # 只在 build/release/ 生成 zip 和 appcast，不上传
open build/Harbor.app        # 运行；也可以直接跑 build/Harbor.app/Contents/MacOS/Harbor <目录>
scripts/test.sh              # 单测（没装 Xcode 时会自动补上 Swift Testing 的路径）
swift run -c release HarborBench make <目录> 100000   # 生成测试目录
swift run -c release HarborBench read <目录>          # 读目录、排序耗时基准
```

验证用环境变量（release 构建也有效）：

- `HARBOR_TIMING=1`：每次加载目录后在 stderr 打印条目数和耗时
- `HARBOR_SNAPSHOT=<png 路径>`：首次加载后把窗口内容渲染成图片，不需要屏幕录制权限（边栏的系统材质、Liquid Glass 画不出来；玻璃面板改画里面的内容，视觉效果要在真机上看）
- `HARBOR_SCRIPT=smoke`：在启动目录里自动走一遍拷贝、粘贴、撤销、重做、冲突、新建、重命名、废纸篓、剪切、复制，用假的废纸篓，结果打到 stderr，跑完退出。要用 `open` 启动，直接跑可执行文件时窗口成不了 key window：

  ```sh
  mkdir -p /tmp/smoke/folder && echo A > /tmp/smoke/a.txt && echo B > /tmp/smoke/b.txt
  open -W -n --env HARBOR_SCRIPT=smoke --stderr /tmp/smoke.log build/Harbor.app --args /tmp/smoke
  ```

  `--stderr` 是追加写入，重跑前先删掉旧日志。
- `HARBOR_SCRIPT=m3`：双栏（Tab 切换、F5/F6 互拷）、标签页、命令面板、快速跳转、拷贝路径。启动目录里要有 `a.txt`、`b.txt`、`folder/`、`folder2/`；跑完恢复「双栏」偏好
- `HARBOR_SCRIPT=m4`：内嵌终端，用你真实的 shell 和配置跑：双向同步、命令运行时排队、半截输入保留、终端里禁用 ⌘⌫ / ⌘Z、粘贴文件路径、exit。启动目录里要有 `folder/`、`folder2/`、`with space/`
- `HARBOR_SCRIPT=m5`：压缩、解压（撤销重做、双击解压、7z、加密 zip 输错再输对、取消密码、压缩到一半取消）。准备方法：

  ```sh
  mkdir -p /tmp/m5/docs/sub && cd /tmp/m5 && echo -n A > docs/a.txt && echo -n B > docs/sub/b.txt && echo -n X > x.txt
  echo -n "top secret" > secret.txt && zip -q -P pw enc.zip secret.txt && rm secret.txt
  dd if=/dev/urandom of=big.bin bs=1m count=60
  ```
- `HARBOR_SCRIPT=m8`：图标视图（缩略图、选中同步、重命名、双击、右键）、主页、分类、常驻查询和快照、智能分类、标签、快速搜索、边栏分组、回到真实目录。快照写在启动目录的 `.snapshots/` 里，测试改过的偏好结束前恢复。启动目录里要有 `a.txt`、`b.txt`、`folder/`、`pic.png`。分类查询用你主目录里真实的文件（只读）；桌面、文稿、下载要用户授权，脚本里跳过这三个目录
- `HARBOR_SNAPSHOT_DIR=<目录>`：配合 m3 / m4 / m8 保存截图
- 应用不在前台（你在用别的应用）时，只有 key window 才能测的菜单检查会标「跳过」，收起边栏的动画也不执行

## 签名和发布

不买 Developer ID、不公证，零成本：

- **签名**：`bundle.sh` 优先用登录钥匙串里的自签名证书「Harbor Self-Signed」（私钥只允许 codesign 使用）。签名身份固定，授予过的「完全磁盘访问权限」等在更新后保留；没有证书时退回临时签名。换机器要重新建证书（openssl 生成后 `security import … -T /usr/bin/codesign`），已安装的用户会要求重新授权
- **更新**：Sparkle 2，更新源是 `https://github.com/unify-tools/Harbor/releases/latest/download/appcast.xml`（仓库必须公开）。EdDSA 私钥在登录钥匙串（账户 `dev.lakes.harbor`），丢了就没法给已安装的版本推更新，备份：`.build/artifacts/sparkle/Sparkle/bin/generate_keys --account dev.lakes.harbor -x <文件>`
- **发布**：改 `Resources/Info.plist` 的 `CFBundleShortVersionString`，提交并推送，再跑 `scripts/release.sh`。构建号自动取提交数。上传用 gh 的 Lakes2 账号（`gh auth login` 加上，不用切换默认账号）
- **首次安装**：别人下载后第一次打开会被系统拦下，要到「系统设置 → 隐私与安全性」点「仍要打开」；之后经 Sparkle 的更新不会再拦
- `HARBOR_FEED_URL=<appcast 地址>`：调试更新流程，启动后后台检查、自动下载并立即安装。会往偏好里写 `SU*` 键，测完删掉

## 快捷键和命令（M3 起新增）

- ⌘N 新建窗口，⌘T 新建标签页，⌘双击 / 右键「在新标签页中打开」；多选打开时文件夹各开一个后台标签页
- ⌘F 快速搜索：工具栏搜索框按文件名搜（含文件夹），在文件夹里默认搜这个文件夹及子文件夹，搜不到可以一键改成所有位置；清空回到原来的位置
- 分组方式（显示 → 分组方式，或工具栏的分组按钮）：无 / 名称 / 种类 / 应用程序 / 上次打开日期 / 添加日期 / 修改日期 / 创建日期 / 大小 / 标签。列表里每组一行吸顶的组标题，图标视图每组一个分区；所有窗口共用
- ⌘1 图标视图（缩略图）、⌘2 列表视图，所有窗口共用
- ⇧⌘F 主页：分类卡片（文档、图片、视频、音频、压缩包和自建的智能分类，显示数量）+ 最近打开的文件
- ⌥⌘N 新建智能分类：文件名包含、类型、时间条件，可开「智能更新」；卡片右键可固定到快速访问、编辑、删除
- ⌃⌘T 添加至 / 从快速访问移除（文件夹右键也有）
- 边栏：主页、快速访问、存储位置（磁盘按树展开）、标签（按 Finder 标签查找）
- 右键「打开方式」：列出能打开所选项目的应用（默认应用在前），「其他…」可以挑任意应用
- 空格 / ⌘Y 快速查看（预览打开时方向键换文件，空格或 Esc 关闭）
- ⌘\ 双栏，列表里 Tab 切到另一栏，F5 拷贝到另一栏，F6 移动到另一栏
- ⌘K 命令面板（命令取自主菜单，支持拼音全拼和首字母）
- ⌘P 快速跳转（访问过的文件夹，按频率 + 最近访问排序；⌘↩ 在新标签页打开）
- ⌃` 终端：没显示就打开并聚焦，焦点不在终端就聚焦，焦点在终端就收起（shell 保留）；`exit` 后自动收起
- 工具栏右侧：双栏、终端（单纯显示 / 收起）两个按钮
- 文件 → 压缩：ZIP / tar.gz / tar.xz / 7z；解压；双击压缩包 = 解压到当前文件夹（和 Finder 一样），「用默认应用打开」走系统默认
- ⌥⌘C 拷贝所选路径（没有选中项时拷贝当前文件夹），⌥⇧⌘C 拷贝当前文件夹路径；地址栏右键也能拷贝

## 结构

- `Sources/HarborCore`：与界面无关，有单测
  - `DirectoryReader`：用 `getattrlistbulk` 批量读目录
  - `FileSorter`：按 Finder 规则排序，文件名预先算 `UCCollationKey`
  - `DirectoryWatcher`：FSEvents 监听当前目录
  - `NavigationHistory`、`PathInput`：前进后退、地址栏解析和 Tab 补全
  - `FileTransfer`：批量拷贝 / 移动，处理冲突、进度、取消；优先 `clonefile`，不行再 `copyfile`
  - `FileActions`：新建、重命名、废纸篓、删除，以及撤销步骤的执行
  - `FuzzyMatcher`、`PinyinKeys`：模糊匹配和拼音检索键
  - `VisitStore`、`JumpRanking`：访问记录（frecency，算法类似 zoxide）和快速跳转排序
  - `ShellIntegration`：终端的 zsh / bash 注入脚本、OSC 7 解析、路径转义
  - `FileGrouper`：分组（组按固定顺序：日期新的在前、大的在前、名称按字母，组内保持排序）。上次打开（Spotlight）、添加日期、标签只在选了对应分组时读
  - `SmartQuery`：分类、标签、智能分类的条件拼成 Spotlight 查询；`SpotlightFilter` 过滤隐藏目录、node_modules、包内部的结果
  - `Archives`：用系统自带的 libarchive（3.7.4，带 zlib / xz / bzip2，没有 zstd）压缩、解压
- `Sources/CArchive`：libarchive 的 C 声明。SDK 只有链接桩没有头文件，这里按官方 3.7.4 头文件声明用到的部分
- `Sources/Harbor`：AppKit 界面（窗口、边栏、文件列表、地址栏、菜单）
  - `FileOperationCenter`：所有窗口共用的文件操作入口和撤销历史
  - `MainWindowController`：一个窗口 / 标签页（系统原生标签），边栏 + 一到两栏浏览区，菜单动作转给活动的那一栏
  - 分组后表格多出组标题行：`itemIndex(forRow:)`、`row(forItem:)`、`selectedItemIndexes` 负责行号和 items 下标的换算，取选中项都走它们
  - `FileGridView`、`BrowserViewController+Grid`：图标视图，和列表共用数据，选中状态以列表为准（现成的文件操作不用改）；`ThumbnailProvider` 缓存缩略图
  - `VirtualLocation`：主页、分类、标签、智能分类编码成 `harbor://` 地址，复用导航和前进后退；`QuickAccessStore`、`SmartCategoryStore` 存快速访问和智能分类
  - `SpotlightCache`：默认分类、最近、标签、智能更新的分类用常驻查询（运行期间不重复搜，Spotlight 增量推送变化，更新合并成每秒最多一次）；结果快照存在 `~/Library/Caches/dev.lakes.harbor/spotlight`，重启后先显示快照再换成最新结果；用过主页的话启动 3 秒后预热。卡片数量另存在偏好 `homeCardCounts`
  - `HomeViewController`、`QueryResultsViewController`、`SpotlightSearch`：主页和搜索结果。查询在后台队列上收集、过滤；只搜主目录下的一级文件夹（不含 ~/Library）。第一次搜桌面 / 文稿 / 下载时系统会请求授权，授权前显示「正在查找…」
  - `PanesContainer`：包住一到两栏浏览区，底部悬浮进度胶囊（NSGlassEffectView），双栏时也只有一份；胶囊显示时各栏列表留出底部余量，最后几行不会被挡住
  - `QuickPanel`：⌘K / ⌘P 共用的玻璃浮层；`CommandPalette`、`QuickJump` 提供内容
  - `AppDelegate`：启动、Sparkle 更新（菜单「检查更新…」；调试脚本运行时、`swift run` 时不启用）
  - `RecentPlaces`：访问记录存在 `~/Library/Application Support/Harbor/visits.json`
  - `TerminalPanel`：SwiftTerm 内嵌终端，和活动的那一栏双向同步目录；四周留边距，颜色跟系统深浅色；按 shell 选路径的引号规则（sh 系 / fish，不认识的 shell 遇到特殊字符拒绝插入）

## 终端的目录同步

- 终端 → 浏览区：shell 每次显示提示符时用 OSC 7 报告当前目录，活动的那一栏跟着跳
- 浏览区 → 终端：把目标写进 `$HARBOR_CD_FILE`，再发一个私有按键序列 `ESC [5555~`，触发注入的 zle 小部件（bash 用 `bind -x`）静默 `cd` 并重画提示符，不留 cd 命令，也不清掉输入到一半的内容。终端里在跑命令时（前台进程组不是 shell）先排队，回到提示符再发
- 只认带会话令牌的目录报告：集成脚本把每次随机生成的令牌放在 OSC 7 的主机名位置，令牌不 export，命令输出、文件内容、ssh 远端都伪造不了。没注入的 shell 退回「本机主机名 + 前台是 shell」
- 写进 `$HARBOR_CD_FILE` 的目标被 shell 取走后就删掉；文件一秒多没被取走（比如 `exec` 了别的 shell），就不再发按键
- 拖进终端、粘贴的路径会转义；含控制字符的文件名用 `$'…\xNN…'`，防止注入命令
- 调试脚本（`HARBOR_SCRIPT`）运行时 shell 不写历史
- 注入方式和 VS Code 类似：zsh 把 `ZDOTDIR` 指到 `~/Library/Application Support/Harbor/shell-integration/zsh`，那里的启动文件先加载你自己的同名文件；bash 用 `--rcfile`。脚本每次启动程序时重写。fish 等其他 shell 不注入，只是不能同步
- `Sources/HarborBench`：性能基准

## 注意

临时签名每次构建都会变，授予过的「完全磁盘访问权限」要重新勾选。

## 压缩解压

- 解压先写到目标目录里的隐藏暂存目录（`.harbor-extract-*`），完成后挪到位；只有一个顶层项目就直接放出来，否则放进以压缩包命名的文件夹，重名加编号
- 拒绝绝对路径、带 `..` 的路径、借符号链接写到外面；被拒绝的条目汇总提示。压缩包带 `com.apple.quarantine` 时解出来的东西也带上
- 加密压缩包弹窗要密码，输错可以重试；`__MACOSX` 资源分支不解出来
- 压缩写到隐藏临时文件（`.harbor-compress-*`）再改名；不收 `.DS_Store`；符号链接按链接保存；zip 文件名用 UTF-8
- 压缩、解压都能在进度条上取消，取消或出错时不留临时文件；都能撤销（结果移到废纸篓）
