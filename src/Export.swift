import Foundation
import Darwin

// Walk relative to open directory descriptors. Existing symlinks in the destination
// must never redirect one card's files into another card or outside the chosen folder.
struct Destination {
    let root: URL

    private func ioError(_ path: [String], _ code: Int32 = errno) -> ExportError {
        ExportError("\(path.joined(separator: "/")) · \(String(cString: strerror(code)))")
    }

    private func atParent<T>(_ path: [String], _ work: (Int32, String) throws -> T) throws -> T {
        guard let name = path.last, path.allSatisfy(CameraObject.validName) else {
            throw ExportError("目标相对路径无效。")
        }
        let flags = O_DIRECTORY | O_RDONLY | O_NOFOLLOW | O_CLOEXEC
        var folder = open(root.path, flags)
        guard folder >= 0 else { throw ioError([root.path]) }
        defer { close(folder) }
        for part in path.dropLast() {
            if mkdirat(folder, part, 0o755) != 0 && errno != EEXIST { throw ioError(path) }
            let child = openat(folder, part, flags)
            guard child >= 0 else { throw ioError(path) }
            close(folder)
            folder = child
        }
        return try work(folder, name)
    }

    private func exists(_ folder: Int32, _ name: String, path: [String]) throws -> Bool {
        var status = stat()
        if fstatat(folder, name, &status, AT_SYMLINK_NOFOLLOW) == 0 {
            guard status.st_mode & S_IFMT == S_IFREG else { throw ExportError("\(path.joined(separator: "/")) 已被目录或链接占用。") }
            return true
        }
        guard errno == ENOENT else { throw ioError(path) }
        return false
    }

    func alreadyPresent(_ path: [String]) throws -> Bool {
        try atParent(path) { try exists($0, $1, path: path) }
    }

    // Publish only a completely written file. RENAME_EXCL also protects against
    // another exporter creating the same name after the initial existence check.
    func save(_ data: Data, to path: [String]) throws -> Bool {
        try atParent(path) { folder, name in
            let temp = ".z8e-\(UUID().uuidString).partial"
            let fd = openat(folder, temp, O_CREAT | O_EXCL | O_WRONLY | O_CLOEXEC, 0o600)
            guard fd >= 0 else { throw ioError(path) }
            defer { unlinkat(folder, temp, 0) }
            do {
                defer { close(fd) }
                try data.withUnsafeBytes { bytes in
                    var offset = 0
                    while offset < bytes.count {
                        let count = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                        if count < 0 && errno == EINTR { continue }
                        guard count > 0 else { throw ioError(path) }
                        offset += count
                    }
                }
                guard fsync(fd) == 0 else { throw ioError(path) }
            }
            if renameatx_np(folder, temp, folder, name, UInt32(RENAME_EXCL)) == 0 { return true }
            guard errno == EEXIST, try exists(folder, name, path: path) else { throw ioError(path) }
            return false
        }
    }
}

struct ExportProgress {
    let total: Int
    var written = 0
    var skipped = 0
    var current = ""
    var failure: String?
    var processed: Int { written + skipped }
    var summary: String {
        let counts = "已导出 \(written) 张，已有同名文件跳过 \(skipped) 张"
        if let failure { return "导出中断 · \(counts)\n\(current) · \(failure)" }
        if total == 0 { return "所选范围内没有照片。" }
        if processed == total { return "处理完成 · \(counts)" }
        return counts
    }
}

@MainActor
func exportPhotos(_ items: [ExportItem], destination: Destination,
                  read: (ExportItem) async throws -> Data,
                  progress: (ExportProgress) -> Void) async -> ExportProgress {
    var state = ExportProgress(total: items.count)
    progress(state)
    for item in items {
        let path = item.path
        state.current = path.joined(separator: "/")
        progress(state)
        do {
            try Task.checkCancellation()
            let exists = try await Task.detached { try destination.alreadyPresent(path) }.value
            if exists {
                state.skipped += 1
            } else {
                let data = try await read(item)
                try Task.checkCancellation()
                guard data.count > 0, data.count == Int(item.entry.object.size) else {
                    throw ExportError("原片长度校验失败。")
                }
                let saved = try await Task.detached { try destination.save(data, to: path) }.value
                if saved { state.written += 1 } else { state.skipped += 1 }
            }
            try Task.checkCancellation()
        } catch {
            state.failure = error is CancellationError ? "相机连接或目录已变化。" : error.localizedDescription
            progress(state)
            break
        }
        progress(state)
    }
    return state
}
