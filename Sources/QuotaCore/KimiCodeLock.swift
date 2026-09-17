import Darwin
import Foundation

// MARK: - Kimi Code's renewal lock

/// The lock Kimi Code takes before it renews a sign-in, taken the same way,
/// so QuotaBar and Kimi Code never renew the same refresh token at once:
/// the server rotates it on every renewal, and the second renewal of an old
/// one signs the owner out.
///
/// Kimi Code (the CLI and the desktop app) uses proper-lockfile 4.1.2 on the
/// sentinel `~/.kimi-code/oauth/<name>`, with `stale: 5000` and
/// `realpath: false`. Its protocol, which this follows:
///
/// - **Holding** the lock is owning the directory `<sentinel>.lock`, made
///   with a plain `mkdir`: whoever's `mkdir` succeeds holds it.
/// - **A holder proves it is alive** by setting the directory's mtime to
///   now every 2.5 seconds. Before each touch it checks the mtime is still
///   the one it set last; anything else means someone else touched or
///   replaced the directory, and the lock is compromised. So the directory
///   of a lock QuotaBar does not hold is never touched.
/// - **A lock whose mtime is more than 5 seconds old is stale**: its holder
///   died. It may be removed with `rmdir` and taken with a fresh `mkdir`.
///   QuotaBar is a little stricter than Kimi Code and only takes over a lock
///   that has looked stale, with the same mtime, for at least a second.
/// - **Release** is `rmdir`. QuotaBar removes the directory only while its
///   mtime is still the one it set, so it never removes a lock that has
///   since passed to someone else.
///
/// Kimi Code waits up to a minute for the lock and then gives up without
/// renewing; `KimiCodeRenewal` waits less, which is always safe.
public final class KimiCodeLock: @unchecked Sendable {
    /// proper-lockfile's `stale`, as Kimi Code sets it.
    public static let staleAfter: TimeInterval = 5
    /// proper-lockfile's `update`: half of `stale`.
    public static let touchInterval: TimeInterval = 2.5
    /// Kimi Code's `retries.minTimeout`.
    public static let retryInterval: TimeInterval = 0.5

    /// The lock directory, `<sentinel>.lock`.
    public let directory: URL

    private let guardLock = NSLock()
    private let queue = DispatchQueue(label: "bar.quota.kimi-code-lock")
    private var timer: DispatchSourceTimer?
    /// The mtime this holder set last, in whole milliseconds — what
    /// proper-lockfile compares, since a JavaScript `Date` holds no finer.
    private var ownMtime: Int64
    private var lastTouch: Date
    private var compromised = false
    private var released = false

    private static let registryLock = NSLock()
    nonisolated(unsafe) private static var held: [ObjectIdentifier: KimiCodeLock] = [:]

    private init(directory: URL, mtime: Int64, touchInterval: TimeInterval) {
        self.directory = directory
        self.ownMtime = mtime
        self.lastTouch = Date()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + touchInterval, repeating: touchInterval)
        timer.setEventHandler { [weak self] in self?.touch() }
        self.timer = timer
        timer.resume()
        Self.registryLock.withLock { Self.held[ObjectIdentifier(self)] = self }
    }

    deinit {
        timer?.cancel()
    }

    // MARK: Taking it

    /// A lock that looked stale, remembered so it is taken over only when it
    /// still looks the same a second later.
    public struct StaleSighting: Sendable, Equatable {
        let mtime: Int64
        let seenAt: Date
    }

    public enum Attempt {
        case acquired(KimiCodeLock)
        /// Someone else holds it, or it looked stale for the first time.
        case locked
        /// The file system said no (`errno`); worth another try, as
        /// proper-lockfile retries on any error.
        case failed(Int32)
    }

    /// `mkdir <sentinel>.lock` once, with proper-lockfile's handling of a
    /// directory that is already there.
    public static func attempt(
        directory: URL,
        now: Date,
        sighting: inout StaleSighting?,
        touchInterval: TimeInterval = KimiCodeLock.touchInterval) -> Attempt
    {
        let path = directory.path
        if mkdir(path, 0o777) == 0 { return took(directory, touchInterval: touchInterval) }
        guard errno == EEXIST else { return .failed(errno) }

        var info = stat()
        guard stat(path, &info) == 0 else {
            // Released between the two calls: one more mkdir, as proper-lockfile does.
            guard errno == ENOENT else { return .failed(errno) }
            if mkdir(path, 0o777) == 0 { return took(directory, touchInterval: touchInterval) }
            return errno == EEXIST ? .locked : .failed(errno)
        }
        let mtime = milliseconds(info.st_mtimespec)
        guard mtime < milliseconds(now) - Int64(staleAfter * 1000) else {
            sighting = nil
            return .locked
        }
        guard let seen = sighting, seen.mtime == mtime, now.timeIntervalSince(seen.seenAt) >= 1 else {
            if sighting?.mtime != mtime { sighting = StaleSighting(mtime: mtime, seenAt: now) }
            return .locked
        }
        // Stale for a second or more, unchanged: its holder is gone.
        sighting = nil
        guard rmdir(path) == 0 || errno == ENOENT else { return .failed(errno) }
        if mkdir(path, 0o777) == 0 { return took(directory, touchInterval: touchInterval) }
        return errno == EEXIST ? .locked : .failed(errno)
    }

    /// Just made the directory: stamp it, so the first touch has an mtime
    /// of its own to compare with. A directory that cannot be stamped is
    /// given back, as proper-lockfile does.
    private static func took(_ directory: URL, touchInterval: TimeInterval) -> Attempt {
        guard let mtime = stamp(directory.path) else {
            let failure = errno
            rmdir(directory.path)
            return .failed(failure)
        }
        return .acquired(KimiCodeLock(directory: directory, mtime: mtime, touchInterval: touchInterval))
    }

    // MARK: Holding it

    /// True once someone else has touched, replaced or removed the directory,
    /// or it could not be touched within the stale threshold: others may
    /// take the lock, so nothing new may be started under it.
    public var isCompromised: Bool {
        guardLock.withLock { compromised }
    }

    func touch() {
        guardLock.lock()
        defer { guardLock.unlock() }
        guard !released, !compromised else { return }
        let path = directory.path
        var info = stat()
        guard stat(path, &info) == 0 else {
            if errno == ENOENT || Date().timeIntervalSince(lastTouch) > Self.staleAfter { compromise() }
            return
        }
        guard Self.milliseconds(info.st_mtimespec) == ownMtime else {
            compromise()
            return
        }
        guard let mtime = Self.stamp(path) else {
            if errno == ENOENT || Date().timeIntervalSince(lastTouch) > Self.staleAfter { compromise() }
            return
        }
        ownMtime = mtime
        lastTouch = Date()
    }

    private func compromise() {
        compromised = true
        timer?.cancel()
        timer = nil
    }

    // MARK: Giving it back

    /// Stops touching and removes the directory while it is still this
    /// holder's. Safe to call more than once.
    public func release() {
        guardLock.lock()
        let first = !released
        if first {
            released = true
            timer?.cancel()
            timer = nil
            var info = stat()
            if !compromised, stat(directory.path, &info) == 0, Self.milliseconds(info.st_mtimespec) == ownMtime {
                rmdir(directory.path)
            }
        }
        guardLock.unlock()
        if first {
            Self.registryLock.withLock { _ = Self.held.removeValue(forKey: ObjectIdentifier(self)) }
        }
    }

    /// Every lock still held, given back — for quitting mid-renewal, as
    /// proper-lockfile does on exit.
    public static func releaseAll() {
        let locks = registryLock.withLock { Array(held.values) }
        for lock in locks { lock.release() }
    }

    // MARK: Time on disk

    static func milliseconds(_ time: timespec) -> Int64 {
        Int64(time.tv_sec) * 1000 + Int64(time.tv_nsec) / 1_000_000
    }

    static func milliseconds(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1000).rounded(.down))
    }

    /// Sets the directory's mtime to now in whole milliseconds, and returns
    /// what the file system kept — a volume with coarser times rounds it.
    private static func stamp(_ path: String) -> Int64? {
        let now = milliseconds(Date())
        let spec = timespec(tv_sec: time_t(now / 1000), tv_nsec: Int((now % 1000) * 1_000_000))
        var times = [spec, spec]
        guard utimensat(AT_FDCWD, path, &times, 0) == 0 else { return nil }
        var info = stat()
        guard stat(path, &info) == 0 else { return nil }
        return milliseconds(info.st_mtimespec)
    }
}
