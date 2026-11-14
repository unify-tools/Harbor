import Foundation

/// 浏览器式的前进 / 后退历史
public struct NavigationHistory: Sendable {
    public private(set) var current: URL?
    private var backStack: [URL] = []
    private var forwardStack: [URL] = []
    private let limit: Int

    public init(limit: Int = 200) {
        self.limit = limit
    }

    public var canGoBack: Bool { !backStack.isEmpty }
    public var canGoForward: Bool { !forwardStack.isEmpty }

    /// 访问新位置：当前位置入后退栈，清空前进栈。重复访问当前位置不记录。
    public mutating func visit(_ url: URL) {
        if let current {
            guard current.pathKey != url.pathKey else { return }
            backStack.append(current)
            if backStack.count > limit { backStack.removeFirst(backStack.count - limit) }
        }
        forwardStack.removeAll()
        current = url
    }

    public mutating func goBack() -> URL? {
        guard let target = backStack.popLast() else { return nil }
        if let current { forwardStack.append(current) }
        current = target
        return target
    }

    public mutating func goForward() -> URL? {
        guard let target = forwardStack.popLast() else { return nil }
        if let current { backStack.append(current) }
        current = target
        return target
    }
}
