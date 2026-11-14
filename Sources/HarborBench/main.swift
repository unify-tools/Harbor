import Foundation
import HarborCore

// 用法：
//   HarborBench make <目录> <数量>   在目录里生成指定数量的空文件
//   HarborBench read <目录> [轮数]   对比 getattrlistbulk 和 FileManager 的读取耗时，以及各种排序耗时

func measure(_ runs: Int, _ body: () throws -> Void) rethrows -> Double {
    var samples: [Double] = []
    for _ in 0..<runs {
        let start = ContinuousClock.now
        try body()
        let elapsed = ContinuousClock.now - start
        samples.append(Double(elapsed.components.attoseconds) / 1e15 + Double(elapsed.components.seconds) * 1000)
    }
    return samples.sorted()[samples.count / 2]
}

let args = CommandLine.arguments
guard args.count >= 3 else {
    print("用法: HarborBench make <目录> <数量> | read <目录> [轮数]")
    exit(1)
}
let dir = URL(filePath: args[2], directoryHint: .isDirectory)

switch args[1] {
case "make":
    let count = Int(args[3]) ?? 100_000
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let exts = ["txt", "png", "swift", "pdf", "json", "md", "jpg", ""]
    for i in 0..<count {
        let ext = exts[i % exts.count]
        let name = ext.isEmpty ? "file\(i)" : "file\(i).\(ext)"
        FileManager.default.createFile(atPath: dir.appending(path: name).path, contents: nil)
    }
    print("生成 \(count) 个文件: \(dir.path)")

case "read":
    let runs = args.count > 3 ? Int(args[3]) ?? 5 : 5
    var items: [FileItem] = []
    let bulk = try measure(runs) { items = try DirectoryReader.read(dir) }
    print("条目数: \(items.count)")
    print(String(format: "getattrlistbulk: %8.1f ms", bulk))

    let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey, .creationDateKey, .isHiddenKey, .isPackageKey]
    let fm = try measure(runs) {
        let urls = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys)
        for url in urls { _ = try url.resourceValues(forKeys: Set(keys)) }
    }
    print(String(format: "FileManager:     %8.1f ms", fm))

    for key in FileSortOrder.Key.allCases {
        let order = FileSortOrder(key: key)
        let t = measure(runs) { _ = FileSorter.arrange(items, showHidden: false, order: order) }
        print(String(format: "排序 %-9@ %8.1f ms", key.rawValue as NSString, t))
    }

default:
    print("未知命令 \(args[1])")
    exit(1)
}
