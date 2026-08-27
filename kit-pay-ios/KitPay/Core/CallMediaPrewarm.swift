import Foundation
import LiveKit

/// Pure rules for warming the network path to the media server before a call connects.
///
/// Joining a LiveKit room begins with a DNS lookup and a TLS handshake to the SFU. On a cold
/// cellular link that round trip is a large share of the gap between answering and hearing the
/// other person, and it happens after the answer, where the user is watching. The SFU host is the
/// same for every call in a deployment, so the host Kit last connected to can be warmed while the
/// phone is still ringing — or while an outgoing call is still being placed — and the eventual dial
/// reuses the resolved address and TLS session.
enum CallMediaPrewarmPolicy {
    /// Roughly two rings. Warming more often than this spends a request without making the dial
    /// any faster, because the connection is still pooled.
    static let cooldown: TimeInterval = 15

    /// Only the origin is kept: no room, no token, no query. A URL that carries credentials is
    /// rejected outright rather than written to disk.
    static func storableOrigin(for url: URL) -> URL? {
        guard let scheme = url.scheme?.lowercased(),
              scheme == "wss" || scheme == "ws",
              let host = url.host,
              !host.isEmpty,
              url.user == nil,
              url.password == nil
        else { return nil }
        var components = URLComponents()
        components.scheme = scheme
        components.host = host
        components.port = url.port
        return components.url
    }

    /// A backwards clock (manual change, or a restore) must warm rather than latch.
    static func shouldPrewarm(lastAttempt: Date?, now: Date) -> Bool {
        guard let lastAttempt else { return true }
        let elapsed = now.timeIntervalSince(lastAttempt)
        return elapsed < 0 || elapsed >= cooldown
    }
}

/// Best effort by construction: every failure is swallowed, and nothing here is on the path a call
/// depends on. A prewarm that never completes simply leaves the connect as slow as it is today.
@MainActor
final class CallMediaPrewarmer {
    static let shared = CallMediaPrewarmer()

    private static let storageKey = "kit.calls.media-origin"

    private let defaults: UserDefaults
    private let warm: @MainActor @Sendable (URL) async -> Void
    private var lastAttempt: Date?
    private var inFlight: Task<Void, Never>?

    init(
        defaults: UserDefaults = .standard,
        warm: (@MainActor @Sendable (URL) async -> Void)? = nil
    ) {
        self.defaults = defaults
        self.warm = warm ?? { url in
            // A throwaway room only resolves and warms; it never publishes, joins or holds media.
            // `prepareConnection` is deliberately given no token: Kit's admission tokens are
            // short-lived and call-scoped, and the host is all that has to be resolved early.
            let room = Room()
            try? await room.prepareConnection(url: url.absoluteString)
        }
    }

    /// Recorded only after media actually connected, so a misconfigured or hostile URL that never
    /// worked is never warmed on a later call.
    func rememberConnectedMediaURL(_ url: URL) {
        guard let origin = CallMediaPrewarmPolicy.storableOrigin(for: url) else { return }
        defaults.set(origin.absoluteString, forKey: Self.storageKey)
    }

    var knownMediaOrigin: URL? {
        guard let stored = defaults.string(forKey: Self.storageKey),
              let url = URL(string: stored)
        else { return nil }
        return CallMediaPrewarmPolicy.storableOrigin(for: url)
    }

    /// Fire-and-forget. Safe to call from a VoIP push, from the dial button, and from both at once.
    func prewarm(now: Date = Date()) {
        guard inFlight == nil,
              CallMediaPrewarmPolicy.shouldPrewarm(lastAttempt: lastAttempt, now: now),
              let origin = knownMediaOrigin
        else { return }
        lastAttempt = now
        inFlight = Task { @MainActor in
            await self.warm(origin)
            self.inFlight = nil
        }
    }

    /// Signing out must not leave a warm path to another deployment's media server, and a test must
    /// be able to start from nothing.
    func forget() {
        inFlight?.cancel()
        inFlight = nil
        lastAttempt = nil
        defaults.removeObject(forKey: Self.storageKey)
    }
}
