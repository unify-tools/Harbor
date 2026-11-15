import AppKit

/// 主菜单。自定义动作的 target 都是 nil，沿响应链交给 MainWindowController。
/// 快捷键和 Finder 保持一致。
@MainActor
enum MainMenu {
    static func make() -> NSMenu {
        let main = NSMenu()

        main.addItem(submenu("Harbor", [
            item("关于 Harbor", #selector(NSApplication.orderFrontStandardAboutPanel(_:))),
            item("检查更新…", #selector(AppDelegate.checkForUpdates(_:))),
            .separator(),
            item("隐藏 Harbor", #selector(NSApplication.hide(_:)), "h"),
            item("隐藏其他", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]),
            item("全部显示", #selector(NSApplication.unhideAllApplications(_:))),
            .separator(),
            item("退出 Harbor", #selector(NSApplication.terminate(_:)), "q"),
        ]))

        main.addItem(submenu("文件", [
            item("新建窗口", #selector(MainWindowController.newWindow(_:)), "n"),
            item("新建标签页", #selector(NSResponder.newWindowForTab(_:)), "t"),
            item("新建文件夹", #selector(BrowserViewController.newFolder(_:)), "n", [.command, .shift]),
            item("新建智能分类…", #selector(BrowserViewController.newSmartCategory(_:)), "n", [.command, .option]),
            item("搜索…", #selector(MainWindowController.focusSearch(_:)), "f"),
            .separator(),
            item("打开", #selector(MainWindowController.openSelection(_:)), "o"),
            item("在新标签页中打开", #selector(BrowserViewController.openInNewTab(_:))),
            .separator(),
            // 回车重命名由列表自己处理，这里不设快捷键，以免抢走文本框里的回车
            item("重命名", #selector(BrowserViewController.renameSelection(_:))),
            item("复制", #selector(BrowserViewController.duplicate(_:)), "d"),
            .separator(),
            submenu("压缩", [
                item("压缩为 ZIP", #selector(BrowserViewController.compressZip(_:))),
                item("压缩为 tar.gz", #selector(BrowserViewController.compressTarGz(_:))),
                item("压缩为 tar.xz", #selector(BrowserViewController.compressTarXz(_:))),
                item("压缩为 7z", #selector(BrowserViewController.compress7z(_:))),
            ]),
            item("解压", #selector(BrowserViewController.extractSelection(_:))),
            item("用默认应用打开", #selector(BrowserViewController.openWithDefaultApp(_:))),
            item("快速查看", #selector(BrowserViewController.toggleQuickLook(_:)), "y"),
            item("添加至快速访问", #selector(BrowserViewController.toggleQuickAccess(_:)), "t", [.command, .control]),
            .separator(),
            item("移到废纸篓", #selector(BrowserViewController.moveToTrash(_:)), "\u{8}"),
            item("立即删除…", #selector(BrowserViewController.deleteImmediately(_:)), "\u{8}", [.command, .option]),
            .separator(),
            // 双栏文件管理器的传统按键
            item("拷贝到另一栏", #selector(MainWindowController.copyToOtherPane(_:)), key(NSF5FunctionKey), []),
            item("移动到另一栏", #selector(MainWindowController.moveToOtherPane(_:)), key(NSF6FunctionKey), []),
            .separator(),
            item("关闭窗口", #selector(NSWindow.performClose(_:)), "w"),
        ]))

        main.addItem(submenu("编辑", [
            item("撤销", Selector(("undo:")), "z"),
            item("重做", Selector(("redo:")), "z", [.command, .shift]),
            .separator(),
            item("剪切", #selector(NSText.cut(_:)), "x"),
            item("拷贝", #selector(NSText.copy(_:)), "c"),
            item("粘贴", #selector(NSText.paste(_:)), "v"),
            item("移动到这里", #selector(BrowserViewController.pasteMove(_:)), "v", [.command, .option]),
            item("拷贝路径", #selector(BrowserViewController.copyPath(_:)), "c", [.command, .option]),
            item("拷贝当前文件夹路径", #selector(BrowserViewController.copyCurrentPath(_:)), "c", [.command, .option, .shift]),
            item("全选", #selector(NSText.selectAll(_:)), "a"),
        ]))

        main.addItem(submenu("显示", [
            item("图标", #selector(BrowserViewController.showAsIcons(_:)), "1"),
            item("列表", #selector(BrowserViewController.showAsList(_:)), "2"),
            .separator(),
            item("显示隐藏文件", #selector(MainWindowController.toggleHiddenFiles(_:)), ".", [.command, .shift]),
            item("刷新", #selector(MainWindowController.refresh(_:)), "r"),
            .separator(),
            item("双栏", #selector(MainWindowController.toggleDualPane(_:)), "\\"),
            // 列表里按 Tab 也能切换；Tab 不能做菜单快捷键，否则地址栏的 Tab 补全会被抢走
            item("切换到另一栏", #selector(MainWindowController.switchPane(_:))),
            .separator(),
            item("终端", #selector(MainWindowController.toggleTerminal(_:)), "`", [.control]),
            .separator(),
            item("显示/隐藏边栏", #selector(NSSplitViewController.toggleSidebar(_:)), "s", [.command, .control]),
            item("显示标签页栏", #selector(NSWindow.toggleTabBar(_:))),
            item("显示所有标签页", #selector(NSWindow.toggleTabOverview(_:)), "\\", [.command, .shift]),
            item("进入全屏幕", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control]),
            .separator(),
            item("命令面板…", #selector(MainWindowController.showCommandPalette(_:)), "k"),
        ]))

        main.addItem(submenu("前往", [
            item("快速跳转…", #selector(MainWindowController.quickJump(_:)), "p"),
            .separator(),
            item("后退", #selector(MainWindowController.goBack(_:)), "["),
            item("前进", #selector(MainWindowController.goForward(_:)), "]"),
            item("上层文件夹", #selector(MainWindowController.goUp(_:)), key(NSUpArrowFunctionKey)),
            item("打开所选项", #selector(MainWindowController.openSelection(_:)), key(NSDownArrowFunctionKey)),
            .separator(),
            item("主页", #selector(MainWindowController.goHomePage(_:)), "f", [.command, .shift]),
            item("主目录", #selector(MainWindowController.goHome(_:)), "h", [.command, .shift]),
            item("桌面", #selector(MainWindowController.goDesktop(_:)), "d", [.command, .shift]),
            item("文稿", #selector(MainWindowController.goDocuments(_:)), "o", [.command, .shift]),
            item("下载", #selector(MainWindowController.goDownloads(_:)), "l", [.command, .option]),
            item("应用程序", #selector(MainWindowController.goApplications(_:)), "a", [.command, .shift]),
            .separator(),
            item("前往文件夹…", #selector(MainWindowController.editPath(_:)), "g", [.command, .shift]),
            item("编辑路径", #selector(MainWindowController.editPath(_:)), "l"),
        ]))

        let window = submenu("窗口", [
            item("最小化", #selector(NSWindow.performMiniaturize(_:)), "m"),
            item("缩放", #selector(NSWindow.performZoom(_:))),
            .separator(),
            item("显示上一个标签页", #selector(NSWindow.selectPreviousTab(_:)), "{"),
            item("显示下一个标签页", #selector(NSWindow.selectNextTab(_:)), "}"),
            item("将标签页移到新窗口", #selector(NSWindow.moveTabToNewWindow(_:))),
            item("合并所有窗口", #selector(NSWindow.mergeAllWindows(_:))),
        ])
        main.addItem(window)
        NSApp.windowsMenu = window.submenu

        return main
    }

    private static func submenu(_ title: String, _ items: [NSMenuItem]) -> NSMenuItem {
        let menu = NSMenu(title: title)
        items.forEach(menu.addItem)
        let holder = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        holder.submenu = menu
        return holder
    }

    private static func item(_ title: String, _ action: Selector, _ key: String = "", _ modifiers: NSEvent.ModifierFlags = .command) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        return item
    }

    private static func key(_ functionKey: Int) -> String {
        String(Character(UnicodeScalar(UInt16(functionKey))!))
    }
}
