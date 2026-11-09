// Claude Island: a notch ("dynamic island") widget that shows which Claude Code
// desktop sessions are running and which finished turns you haven't read yet.
// Data source: ~/Library/Application Support/Claude/claude-code-sessions/*/*/local_*.json
// Click a row -> claude://claude.ai/epitaxy/<sessionId> opens that conversation.

import AppKit
import SwiftUI
import Combine

// MARK: - Model

struct SessionItem: Identifiable, Equatable {
    let id: String          // local_xxx
    let title: String
    let running: Bool
    let background: Bool    // turn is over but background shells/subagents are still working
    let edgeAt: Double      // ms epoch of the last turn edge (start or end)
}

private struct ParsedSession {
    let id: String
    let title: String
    let archived: Bool
    let edgeAt: Double
    let userAt: Double
    let focusAt: Double
    let isRoutine: Bool     // scheduled-task run
    let cliSessionId: String
    let cwds: [String]
}

final class SessionStore: ObservableObject {
    @Published private(set) var running: [SessionItem] = []
    @Published private(set) var unread: [SessionItem] = []

    private let queue = DispatchQueue(label: "claude-island.scan", qos: .utility)
    private var cache: [String: (Date, ParsedSession?)] = [:]
    private var timer: Timer?
    private let base = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Claude/claude-code-sessions")
    private static let claudeBundleId = "com.anthropic.claudefordesktop"

    // Widget-local "last seen" per session (ms epoch). Claude only stamps
    // lastFocusedAt when you switch INTO a conversation, so a turn that ends while
    // you are watching it would otherwise look unread. Updated whenever Claude is
    // frontmost with that conversation selected, on click, and on "mark read".
    private var seen: [String: Double] {
        get { UserDefaults.standard.dictionary(forKey: "seen") as? [String: Double] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: "seen") }
    }

    // `--demo` shows made-up sessions (for screenshots and trying the UI).
    private(set) var isDemo = false

    func start() {
        if CommandLine.arguments.contains("--demo") {
            isDemo = true
            loadDemo()
            return
        }
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in self?.refresh() }
    }

    // Hand-marked ("explicit") unread sessions the user dismissed in the widget.
    // Pruned once Claude no longer lists them as explicit, so a later re-mark shows again.
    private var dismissedExplicit: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: "dismissedExplicit") ?? []) }
        set { UserDefaults.standard.set(Array(newValue), forKey: "dismissedExplicit") }
    }
    private var lastExplicit = Set<String>()
    private let appUnread = AppUnreadReader()

    private func loadDemo() {
        let now = Date().timeIntervalSince1970 * 1000
        running = [
            SessionItem(id: "demo-1", title: "Refactor the auth middleware", running: true, background: false, edgeAt: now - 4 * 60_000),
            SessionItem(id: "demo-2", title: "Nightly data import", running: true, background: true, edgeAt: now - 52 * 60_000),
        ]
        unread = [
            SessionItem(id: "demo-3", title: "Fix the flaky checkout test", running: false, background: false, edgeAt: now - 2 * 60_000),
            SessionItem(id: "demo-4", title: "Draft release notes for 2.3", running: false, background: false, edgeAt: now - 75 * 60_000),
        ]
    }

    func markSeen(_ ids: [String]) {
        if isDemo {
            unread.removeAll { ids.contains($0.id) }
            return
        }
        let now = Date().timeIntervalSince1970 * 1000
        var s = seen
        for id in ids { s[id] = now }
        seen = s.filter { now - $0.value < 4 * 86400_000 }
        let explicitHit = Set(ids).intersection(lastExplicit)
        if !explicitHit.isEmpty { dismissedExplicit = dismissedExplicit.union(explicitHit) }
        refresh()
    }

    func dismiss(_ item: SessionItem) { markSeen([item.id]) }
    func dismissAllUnread() { markSeen(unread.map(\.id)) }

    func refresh() {
        guard !isDemo else { return }
        let seenSnapshot = seen
        let dismissedExplicitSnapshot = dismissedExplicit
        let claudeFront = NSWorkspace.shared.frontmostApplication?.bundleIdentifier == Self.claudeBundleId
        queue.async { [weak self] in
            guard let self else { return }
            let sessions = self.scan()
            // The conversation currently open in Claude is the most recently focused one.
            let current = sessions.filter { !$0.archived }.max { $0.focusAt < $1.focusAt }
            var seenNow = seenSnapshot
            var watchedId: String? = nil
            if claudeFront, let c = current {
                watchedId = c.id
                seenNow[c.id] = Date().timeIntervalSince1970 * 1000
            }
            let background = self.backgroundSessionIds(sessions)
            let app = self.appUnread.read()
            let (run, unr) = Self.classify(sessions, seen: seenNow, background: background,
                                           app: app, dismissedExplicit: dismissedExplicitSnapshot)
            DispatchQueue.main.async {
                if let app {
                    self.lastExplicit = app.explicit
                    let pruned = self.dismissedExplicit.intersection(app.explicit)
                    if pruned != self.dismissedExplicit { self.dismissedExplicit = pruned }
                }
                if let w = watchedId {
                    var s = self.seen
                    s[w] = seenNow[w]
                    self.seen = s
                }
                if run != self.running { self.running = run }
                if unr != self.unread { self.unread = unr }
            }
        }
    }

    private func scan() -> [ParsedSession] {
        let fm = FileManager.default
        var files: [URL] = []
        for account in (try? fm.contentsOfDirectory(at: base, includingPropertiesForKeys: nil)) ?? [] {
            for org in (try? fm.contentsOfDirectory(at: account, includingPropertiesForKeys: nil)) ?? [] {
                let items = (try? fm.contentsOfDirectory(at: org, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
                files += items.filter { $0.lastPathComponent.hasPrefix("local_") && $0.pathExtension == "json" }
            }
        }
        var paths = Set<String>()
        var out: [ParsedSession] = []
        for url in files {
            let path = url.path
            paths.insert(path)
            let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            if let hit = cache[path], hit.0 == mtime {
                if let p = hit.1 { out.append(p) }
                continue
            }
            let parsed = autoreleasepool { Self.parse(url) }
            cache[path] = (mtime, parsed)
            if let p = parsed { out.append(p) }
        }
        cache = cache.filter { paths.contains($0.key) }
        return out
    }

    private static func parse(_ url: URL) -> ParsedSession? {
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = obj["sessionId"] as? String else { return nil }
        func num(_ k: String) -> Double { (obj[k] as? NSNumber)?.doubleValue ?? 0 }
        let rawTitle = (obj["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let taskId = (obj["scheduledTaskId"] as? String) ?? ""
        return ParsedSession(
            id: id,
            title: rawTitle.isEmpty ? "New session" : rawTitle,
            archived: (obj["isArchived"] as? Bool) ?? false,
            edgeAt: num("lastTurnEdgeAt"),
            userAt: num("latestUserFrameAt"),
            focusAt: num("lastFocusedAt"),
            isRoutine: !taskId.isEmpty,
            cliSessionId: (obj["cliSessionId"] as? String) ?? "",
            cwds: [obj["cwd"] as? String, obj["originCwd"] as? String].compactMap { $0 }
        )
    }

    // MARK: Background work

    private var pidSession: [Int32: String] = [:]

    private static func run(_ path: String, _ args: [String]) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(data: data, encoding: .utf8)
    }

    // Sessions whose turn is over but that still have work going:
    //  1. a shell started by a tool call (background Bash, Monitor, loops) is
    //     still alive under that session's `claude` process, or
    //  2. a subagent transcript was written in the last 90 s.
    private func backgroundSessionIds(_ sessions: [ParsedSession]) -> Set<String> {
        var result = Set<String>()
        if let out = Self.run("/bin/ps", ["-axo", "pid=,ppid=,command="]) {
            var parent: [Int32: Int32] = [:]
            var claudePids = Set<Int32>()
            var shellPids: [Int32] = []
            for line in out.split(separator: "\n") {
                let parts = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
                guard parts.count == 3, let pid = Int32(parts[0]), let ppid = Int32(parts[1]) else { continue }
                let cmd = parts[2]
                parent[pid] = ppid
                if cmd.hasPrefix("/") && cmd.contains("/claude.app/Contents/MacOS/claude ") && cmd.contains("stream-json")
                    && !cmd.contains("/Helpers/disclaimer") {
                    claudePids.insert(pid)
                } else if cmd.contains("shell-snapshots/snapshot-") || cmd.contains("__CLAUDE_CODE_") {
                    shellPids.append(pid)
                }
            }
            var busy = Set<Int32>()
            for sh in shellPids {
                var cur = parent[sh] ?? 0
                for _ in 0..<12 where cur > 1 {
                    if claudePids.contains(cur) { busy.insert(cur); break }
                    cur = parent[cur] ?? 0
                }
            }
            pidSession = pidSession.filter { claudePids.contains($0.key) }
            for pid in busy {
                if pidSession[pid] == nil,
                   let env = Self.run("/bin/ps", ["eww", "-o", "command=", "-p", String(pid)]),
                   let r = env.range(of: #"CLAUDE_CODE_HOST_SESSION_ID=(local_[0-9a-fA-F-]+)"#, options: .regularExpression) {
                    pidSession[pid] = String(env[r].dropFirst("CLAUDE_CODE_HOST_SESSION_ID=".count))
                }
                if let sid = pidSession[pid] { result.insert(sid) }
            }
        }

        let now = Date()
        let projects = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects")
        for s in sessions where !s.archived && !s.cliSessionId.isEmpty && now.timeIntervalSince1970 * 1000 - s.edgeAt < 24 * 3600_000 {
            for cwd in Set(s.cwds) {
                let encoded = String(cwd.map { $0.isASCII && ($0.isLetter || $0.isNumber) ? $0 : "-" })
                let dir = projects.appendingPathComponent(encoded).appendingPathComponent(s.cliSessionId).appendingPathComponent("subagents")
                guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey]) else { continue }
                let fresh = files.contains { f in
                    guard f.pathExtension == "jsonl",
                          let m = (try? f.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate else { return false }
                    return now.timeIntervalSince(m) < 90
                }
                if fresh { result.insert(s.id) }
            }
        }
        return result
    }

    // A turn is in flight when the newest user message arrived at or after the
    // last turn edge (the edge is rewritten again when the turn ends).
    // Unread comes from Claude's own sidebar state (blue dots + hand marks) when it
    // can be read; otherwise falls back to comparing turn-end and focus times.
    private static func classify(_ sessions: [ParsedSession], seen: [String: Double], background: Set<String>,
                                 app: AppUnreadState?, dismissedExplicit: Set<String>) -> ([SessionItem], [SessionItem]) {
        let now = Date().timeIntervalSince1970 * 1000
        let claudeUp = !NSRunningApplication.runningApplications(withBundleIdentifier: claudeBundleId).isEmpty
        var running: [SessionItem] = []
        var unread: [SessionItem] = []

        for s in sessions where !s.archived {
            let handMarked = app?.explicit.contains(s.id) ?? false
            // Routines stay hidden unless you marked one unread yourself.
            if s.isRoutine && !handMarked { continue }
            if s.edgeAt <= 0 && !handMarked { continue }
            let item = SessionItem(id: s.id, title: s.title, running: false, background: false, edgeAt: s.edgeAt)
            if claudeUp && s.userAt >= s.edgeAt && now - s.edgeAt < 12 * 3600_000 {
                running.append(SessionItem(id: s.id, title: s.title, running: true, background: false, edgeAt: s.edgeAt))
                continue
            }
            if background.contains(s.id) {
                running.append(SessionItem(id: s.id, title: s.title, running: true, background: true, edgeAt: s.edgeAt))
                continue
            }
            if let app {
                if handMarked {
                    if !dismissedExplicit.contains(s.id) { unread.append(item) }
                } else if app.unread.contains(s.id) && now - s.edgeAt < 48 * 3600_000
                            && (seen[s.id] ?? 0) < s.edgeAt {
                    unread.append(item)
                }
            } else {
                let lastRead = max(s.focusAt, seen[s.id] ?? 0)
                if s.edgeAt > lastRead + 1000 && now - s.edgeAt < 48 * 3600_000 {
                    unread.append(item)
                }
            }
        }
        return (running.sorted { $0.edgeAt > $1.edgeAt }, unread.sorted { $0.edgeAt > $1.edgeAt })
    }
}

// MARK: - Claude sidebar unread state
//
// The desktop app keeps the sidebar's blue dots in its Chromium localStorage
// (a LevelDB under Local Storage/leveldb), key "epitaxy-unread-v1":
//   {"state":{"unreadIds":[...],"explicitUnreadIds":[...]},"version":0}
// explicitUnreadIds are the ones marked unread by hand. This is a small,
// read-only LevelDB reader (log files + snappy-compressed tables).

struct AppUnreadState {
    let unread: Set<String>
    let explicit: Set<String>
}

final class AppUnreadReader {
    private struct Hit { let seq: UInt64; let value: [UInt8]? }
    private let dir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Claude/Local Storage/leveldb")
    private let key: [UInt8] = Array("_https://claude.ai".utf8) + [0, 1] + Array("epitaxy-unread-v1".utf8)
    private var fileCache: [String: (Date, Int, Hit?)] = [:]

    func read() -> AppUnreadState? {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey]) else { return nil }
        var best: Hit? = nil
        var present = Set<String>()
        for f in files where f.pathExtension == "ldb" || f.pathExtension == "log" {
            let rv = try? f.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            let mtime = rv?.contentModificationDate ?? .distantPast
            let size = rv?.fileSize ?? 0
            present.insert(f.path)
            let hit: Hit?
            if let c = fileCache[f.path], c.0 == mtime, c.1 == size {
                hit = c.2
            } else {
                guard let data = try? Data(contentsOf: f) else { continue }
                let bytes = [UInt8](data)
                hit = autoreleasepool { f.pathExtension == "log" ? scanLog(bytes) : scanTable(bytes) }
                fileCache[f.path] = (mtime, size, hit)
            }
            if let h = hit, h.seq > (best?.seq ?? 0) { best = h }
        }
        fileCache = fileCache.filter { present.contains($0.key) }
        guard let v = best?.value, let first = v.first else { return nil }
        let body = Data(v.dropFirst())
        let text = first == 0 ? String(data: body, encoding: .utf16LittleEndian) : String(data: body, encoding: .isoLatin1)
        guard let t = text, let json = try? JSONSerialization.jsonObject(with: Data(t.utf8)) as? [String: Any],
              let state = json["state"] as? [String: Any] else { return nil }
        return AppUnreadState(unread: Set(state["unreadIds"] as? [String] ?? []),
                              explicit: Set(state["explicitUnreadIds"] as? [String] ?? []))
    }

    // MARK: primitives

    private static func varint(_ b: [UInt8], _ i: inout Int, limit: Int? = nil) -> Int? {
        let end = limit ?? b.count
        var r = 0, shift = 0
        while i < end && shift < 63 {
            let c = b[i]; i += 1
            r |= Int(c & 0x7f) << shift
            if c < 0x80 { return r }
            shift += 7
        }
        return nil
    }

    private static func le32(_ b: [UInt8], _ i: Int) -> Int {
        Int(b[i]) | Int(b[i+1]) << 8 | Int(b[i+2]) << 16 | Int(b[i+3]) << 24
    }

    private static func le64(_ b: [UInt8], _ i: Int) -> UInt64 {
        var v: UInt64 = 0
        for k in 0..<8 { v |= UInt64(b[i+k]) << (8 * UInt64(k)) }
        return v
    }

    private static func snappy(_ src: [UInt8]) -> [UInt8]? {
        var i = 0
        guard let n = varint(src, &i), n < 64 << 20 else { return nil }
        var out = [UInt8](); out.reserveCapacity(n)
        while i < src.count {
            let tag = src[i]; i += 1
            switch tag & 3 {
            case 0:
                var len = Int(tag >> 2)
                if len >= 60 {
                    let nb = len - 59
                    guard i + nb <= src.count else { return nil }
                    len = 0
                    for k in 0..<nb { len |= Int(src[i+k]) << (8 * k) }
                    i += nb
                }
                len += 1
                guard i + len <= src.count else { return nil }
                out.append(contentsOf: src[i..<i+len]); i += len
            default:
                var len = 0, off = 0
                if tag & 3 == 1 {
                    guard i < src.count else { return nil }
                    len = Int((tag >> 2) & 7) + 4; off = Int(tag >> 5) << 8 | Int(src[i]); i += 1
                } else if tag & 3 == 2 {
                    guard i + 2 <= src.count else { return nil }
                    len = Int(tag >> 2) + 1; off = Int(src[i]) | Int(src[i+1]) << 8; i += 2
                } else {
                    guard i + 4 <= src.count else { return nil }
                    len = Int(tag >> 2) + 1; off = le32(src, i); i += 4
                }
                guard off > 0, off <= out.count else { return nil }
                let start = out.count - off
                for k in 0..<len { out.append(out[start + k]) }
            }
        }
        return out
    }

    private static func readBlock(_ data: [UInt8], _ off: Int, _ size: Int) -> [UInt8]? {
        guard off >= 0, size >= 0, off + size < data.count else { return nil }
        let raw = Array(data[off..<off+size])
        return data[off+size] == 1 ? snappy(raw) : raw
    }

    private static func entries(_ blk: [UInt8], _ body: ([UInt8], ArraySlice<UInt8>) -> Void) {
        guard blk.count >= 4 else { return }
        let nrest = le32(blk, blk.count - 4)
        let end = blk.count - 4 - 4 * nrest
        guard end >= 0 else { return }
        var i = 0
        var k = [UInt8]()
        while i < end {
            guard let shared = varint(blk, &i, limit: end), let nonShared = varint(blk, &i, limit: end),
                  let vlen = varint(blk, &i, limit: end),
                  shared <= k.count, i + nonShared + vlen <= end else { return }
            k.removeSubrange(shared...)
            k.append(contentsOf: blk[i..<i+nonShared]); i += nonShared
            body(k, blk[i..<i+vlen]); i += vlen
        }
    }

    private static func lessOrEqual(_ a: ArraySlice<UInt8>, _ b: [UInt8]) -> Bool {
        !b.lexicographicallyPrecedes(a)
    }

    private func scanTable(_ data: [UInt8]) -> Hit? {
        guard data.count >= 48 else { return nil }
        var i = data.count - 48
        guard Self.varint(data, &i) != nil, Self.varint(data, &i) != nil,
              let io = Self.varint(data, &i), let isz = Self.varint(data, &i),
              let index = Self.readBlock(data, io, isz) else { return nil }
        var best: Hit? = nil
        var prevSep: [UInt8]? = nil
        Self.entries(index) { sepKey, handle in
            defer { prevSep = Array(sepKey) }
            guard sepKey.count >= 8 else { return }
            let sepUser = sepKey[..<(sepKey.count - 8)]
            // Only blocks whose key range can contain ours.
            guard Self.lessOrEqual(ArraySlice(key), Array(sepUser)) else { return }
            if let p = prevSep, p.count >= 8, !Self.lessOrEqual(p[..<(p.count - 8)], key) { return }
            let h = Array(handle); var j = 0
            guard let off = Self.varint(h, &j), let size = Self.varint(h, &j),
                  let blk = Self.readBlock(data, off, size) else { return }
            Self.entries(blk) { k, v in
                guard k.count >= 8, k.count - 8 == key.count, k[..<(k.count - 8)].elementsEqual(key) else { return }
                let tag = Self.le64(k, k.count - 8)
                let seq = tag >> 8
                if seq > (best?.seq ?? 0) { best = Hit(seq: seq, value: (tag & 0xff) == 1 ? Array(v) : nil) }
            }
        }
        return best
    }

    private func scanLog(_ data: [UInt8]) -> Hit? {
        var best: Hit? = nil
        var rec = [UInt8]()
        var i = 0
        let blockSize = 32768
        while i < data.count {
            let remain = blockSize - (i % blockSize)
            if remain < 7 { i += remain; continue }
            guard i + 7 <= data.count else { break }
            let len = Int(data[i+4]) | Int(data[i+5]) << 8
            let type = data[i+6]
            if len == 0 && type == 0 { i += remain; continue }
            guard i + 7 + len <= data.count else { break }
            if type == 1 || type == 2 { rec.removeAll(keepingCapacity: true) }
            rec.append(contentsOf: data[(i+7)..<(i+7+len)])
            i += 7 + len
            guard type == 1 || type == 4, rec.count >= 12 else { continue }
            let seq = Self.le64(rec, 0)
            let count = Self.le32(rec, 8)
            var j = 12
            for n in 0..<count {
                guard j < rec.count else { break }
                let op = rec[j]; j += 1
                guard let kl = Self.varint(rec, &j), j + kl <= rec.count else { break }
                let k = rec[j..<j+kl]; j += kl
                var v: [UInt8]? = nil
                if op == 1 {
                    guard let vl = Self.varint(rec, &j), j + vl <= rec.count else { break }
                    v = Array(rec[j..<j+vl]); j += vl
                }
                if k.elementsEqual(key) {
                    let s = seq + UInt64(n)
                    if s > (best?.seq ?? 0) { best = Hit(seq: s, value: v) }
                }
            }
            rec.removeAll(keepingCapacity: true)
        }
        return best
    }
}

// MARK: - View state

final class IslandState: ObservableObject {
    @Published var expanded = false
    @Published var notchWidth: CGFloat = 180
    @Published var notchHeight: CGFloat = 32
    @Published var hasNotch = true
}

enum Layout {
    static let sideWing: CGFloat = 30
    static let expandedWidth: CGFloat = 420
    static let rowHeight: CGFloat = 30
    static let maxRows = 12
}

let claudeOrange = Color(red: 0.85, green: 0.47, blue: 0.34)
let unreadBlue = Color(red: 0.30, green: 0.62, blue: 1.0)

// MARK: - Views

struct IslandShape: Shape {
    var bottomRadius: CGFloat
    var animatableData: CGFloat {
        get { bottomRadius }
        set { bottomRadius = newValue }
    }
    func path(in rect: CGRect) -> Path {
        let r = min(bottomRadius, rect.height / 2, rect.width / 2)
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - r))
        p.addQuadCurve(to: CGPoint(x: rect.maxX - r, y: rect.maxY), control: CGPoint(x: rect.maxX, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.minX + r, y: rect.maxY))
        p.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.maxY - r), control: CGPoint(x: rect.minX, y: rect.maxY))
        p.closeSubpath()
        return p
    }
}

struct Spinner: View {
    var size: CGFloat = 12
    var body: some View {
        // Capped at 20 fps so an always-on spinner stays cheap.
        TimelineView(.animation(minimumInterval: 1.0 / 20)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            Circle()
                .trim(from: 0.15, to: 0.85)
                .stroke(claudeOrange, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .frame(width: size, height: size)
                .rotationEffect(.degrees(t.truncatingRemainder(dividingBy: 0.9) / 0.9 * 360))
        }
    }
}

struct CollapsedView: View {
    @ObservedObject var store: SessionStore
    @ObservedObject var state: IslandState
    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: 4) {
                if !store.running.isEmpty {
                    Spinner(size: 11)
                    Text("\(store.running.count)").font(.system(size: 11, weight: .semibold)).foregroundColor(claudeOrange)
                }
            }
            .frame(width: Layout.sideWing)
            Spacer(minLength: 0)
            HStack(spacing: 4) {
                if !store.unread.isEmpty {
                    Circle().fill(unreadBlue).frame(width: 7, height: 7)
                    Text("\(store.unread.count)").font(.system(size: 11, weight: .semibold)).foregroundColor(unreadBlue)
                }
            }
            .frame(width: Layout.sideWing)
        }
        .padding(.horizontal, 4)
        .frame(height: state.notchHeight)
    }
}

struct RowView: View {
    let item: SessionItem
    let open: (SessionItem) -> Void
    let dismiss: (SessionItem) -> Void
    @State private var hover = false

    var body: some View {
        HStack(spacing: 9) {
            ZStack {
                if item.running { Spinner(size: 11) } else { Circle().fill(unreadBlue).frame(width: 7, height: 7) }
            }
            .frame(width: 14)
            Text(item.title)
                .font(.system(size: 12.5, weight: item.running ? .medium : .semibold))
                .foregroundColor(.white)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 6)
            if hover && !item.running {
                Button(action: { dismiss(item) }) {
                    Image(systemName: "checkmark.circle")
                        .font(.system(size: 12))
                        .foregroundColor(.white.opacity(0.7))
                }
                .buttonStyle(.plain)
                .help("Mark as read")
            } else {
                Text(relative(item))
                    .font(.system(size: 11, design: .rounded))
                    .foregroundColor(.white.opacity(0.45))
            }
        }
        .padding(.horizontal, 10)
        .frame(height: Layout.rowHeight)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(hover ? 0.12 : 0)))
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture { open(item) }
    }

    private func relative(_ item: SessionItem) -> String {
        let secs = max(0, Date().timeIntervalSince1970 - item.edgeAt / 1000)
        let text: String
        if secs < 60 { text = "" }
        else if secs < 3600 { text = "\(Int(secs / 60))m" }
        else if secs < 86400 { text = "\(Int(secs / 3600))h" }
        else { text = "\(Int(secs / 86400))d" }
        if item.background { return "background" }
        if item.running { return text.isEmpty ? "running" : "running \(text)" }
        return text.isEmpty ? "just now" : "\(text) ago"
    }
}

struct ExpandedView: View {
    @ObservedObject var store: SessionStore
    @ObservedObject var state: IslandState
    let open: (SessionItem) -> Void

    var items: [SessionItem] { store.running + store.unread }

    var body: some View {
        VStack(spacing: 0) {
            // Header row sits beside the camera notch.
            HStack {
                Text("Claude").font(.system(size: 12, weight: .bold)).foregroundColor(claudeOrange)
                Spacer()
                if !store.unread.isEmpty {
                    Button("Mark all read") { store.dismissAllUnread() }
                        .buttonStyle(.plain)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.white.opacity(0.6))
                }
            }
            .padding(.horizontal, 16)
            .frame(height: state.notchHeight)

            if items.isEmpty {
                Text("Nothing running, nothing unread")
                    .font(.system(size: 12))
                    .foregroundColor(.white.opacity(0.5))
                    .frame(height: Layout.rowHeight + 8)
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 2) {
                        ForEach(items) { item in
                            RowView(item: item, open: open, dismiss: { store.dismiss($0) })
                        }
                    }
                }
                .frame(height: CGFloat(min(items.count, Layout.maxRows)) * (Layout.rowHeight + 2))
            }
        }
        .padding(.horizontal, 8)
        .padding(.bottom, 10)
    }
}

struct IslandRoot: View {
    @ObservedObject var store: SessionStore
    @ObservedObject var state: IslandState
    let open: (SessionItem) -> Void

    var body: some View {
        ZStack(alignment: .top) {
            IslandShape(bottomRadius: state.expanded ? 20 : 10).fill(Color.black)
            if state.expanded {
                ExpandedView(store: store, state: state, open: open)
                    .transition(.opacity)
            } else {
                CollapsedView(store: store, state: state)
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.18), value: state.expanded)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

// MARK: - Window plumbing

final class IslandPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

final class HostingView<Content: View>: NSHostingView<Content> {
    var onEnter: (() -> Void)?
    var onExit: (() -> Void)?
    var onRightClick: ((NSEvent) -> Void)?
    private var area: NSTrackingArea?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area { removeTrackingArea(area) }
        let a = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(a)
        area = a
    }
    override func mouseEntered(with event: NSEvent) { super.mouseEntered(with: event); onEnter?() }
    override func mouseExited(with event: NSEvent) { super.mouseExited(with: event); onExit?() }
    override func rightMouseDown(with event: NSEvent) { onRightClick?(event) }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    let store = SessionStore()
    let state = IslandState()
    var panel: IslandPanel!
    var host: HostingView<IslandRoot>!
    var bag = Set<AnyCancellable>()
    var collapseWork: DispatchWorkItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        panel = IslandPanel(contentRect: NSRect(x: 0, y: 0, width: 200, height: 32),
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.isMovable = false
        panel.hidesOnDeactivate = false

        host = HostingView(rootView: IslandRoot(store: store, state: state, open: { [weak self] in self?.open($0) }))
        host.onEnter = { [weak self] in self?.setExpanded(true) }
        host.onExit = { [weak self] in self?.scheduleCollapse() }
        host.onRightClick = { [weak self] e in self?.showMenu(e) }
        panel.contentView = host

        store.$running.combineLatest(store.$unread)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.layout(animated: true) }
            .store(in: &bag)
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            self?.layout(animated: false)
        }

        layout(animated: false)
        panel.orderFrontRegardless()
        store.start()
    }

    private var screen: NSScreen {
        NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) ?? NSScreen.main ?? NSScreen.screens[0]
    }

    private func measureNotch() {
        let s = screen
        if s.safeAreaInsets.top > 0, let l = s.auxiliaryTopLeftArea, let r = s.auxiliaryTopRightArea {
            state.notchWidth = s.frame.width - l.width - r.width
            state.notchHeight = s.safeAreaInsets.top
            state.hasNotch = true
        } else {
            state.notchWidth = 160
            state.notchHeight = max(24, NSStatusBar.system.thickness)
            state.hasNotch = false
        }
    }

    func layout(animated: Bool) {
        measureNotch()
        let size: NSSize
        if state.expanded {
            let n = store.running.count + store.unread.count
            let rows = n == 0 ? Layout.rowHeight + 8 : CGFloat(min(n, Layout.maxRows)) * (Layout.rowHeight + 2)
            size = NSSize(width: max(Layout.expandedWidth, state.notchWidth + 120), height: state.notchHeight + rows + 10)
        } else {
            let wings = (store.running.isEmpty && store.unread.isEmpty) ? 0 : (Layout.sideWing + 4) * 2
            size = NSSize(width: state.notchWidth + wings, height: state.notchHeight)
        }
        let f = screen.frame
        let frame = NSRect(x: f.midX - size.width / 2, y: f.maxY - size.height, width: size.width, height: size.height)
        if animated {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.2
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().setFrame(frame, display: true)
            }
        } else {
            panel.setFrame(frame, display: true)
        }
    }

    func setExpanded(_ on: Bool) {
        collapseWork?.cancel()
        guard state.expanded != on else { return }
        state.expanded = on
        if on { store.refresh() }
        layout(animated: true)
    }

    func scheduleCollapse() {
        collapseWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            // Stay open while the pointer is still over the panel.
            if self.panel.frame.contains(NSEvent.mouseLocation) { return }
            self.setExpanded(false)
        }
        collapseWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
    }

    func open(_ item: SessionItem) {
        if store.isDemo { setExpanded(false); return }
        if let url = URL(string: "claude://claude.ai/epitaxy/\(item.id)") {
            NSWorkspace.shared.open(url)
        }
        store.markSeen([item.id])
        setExpanded(false)
        // The app writes lastFocusedAt once the conversation is shown; rescan shortly after.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.store.refresh() }
    }

    func showMenu(_ event: NSEvent) {
        let menu = NSMenu()
        let quit = NSMenuItem(title: "Quit Claude Island", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
        menu.addItem(quit)
        NSMenu.popUpContextMenu(menu, with: event, for: host)
    }
}

// `ClaudeIsland --dump-unread` prints what the widget reads from Claude's sidebar state.
if CommandLine.arguments.contains("--dump-unread") {
    if let st = AppUnreadReader().read() {
        print("unread \(st.unread.count): \(st.unread.sorted().joined(separator: " "))")
        print("explicit \(st.explicit.count): \(st.explicit.sorted().joined(separator: " "))")
    } else { print("could not read sidebar state") }
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
