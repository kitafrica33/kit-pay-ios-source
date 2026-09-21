import Foundation

/// What one corrected-conversation projection was computed from.
///
/// The projection itself is a fold over every message the account holds: filter to this
/// conversation, apply the authenticated corrections, drop the correction rows, sort. Kit Pay's
/// own long-history fixture holds 2 000 messages, and the conversation screen reads that fold
/// from about fifteen places in a single `body` — the timeline, two `onChange` comparisons, a
/// `task` identity, and `forwardPayloadItems` inside *every visible bubble's* context menu.
///
/// Recomputing it per read makes touch handling grow with thread length rather than with what is
/// on screen. Measured on the 2 000-message fixture the first pan sample arrived 644 ms after
/// touch-down, against 106 ms on a short thread; under machine load the whole 3.5 s drag was
/// consumed before either pan recognizer reached its 10-point slop, and the timeline moved
/// exactly 0.0 points. Memoizing the fold is therefore a correctness fix for the gesture, not a
/// micro-optimisation.
///
/// The key is deliberately O(1) to build. `AppModel` publishes a monotonic generation for every
/// projection it puts on screen, so equal generations mean equal messages; nothing here hashes a
/// message body or attachment bytes, which is what made the naive `[LocalMessage]` comparisons
/// expensive in the first place.
struct ConversationProjectionKey: Equatable {
    /// `AppModel.stateGeneration` at the moment the projection was read.
    let stateGeneration: UInt64
    /// The fold is per conversation; one generation serves every thread the account holds.
    let conversationID: String
    /// Send Later rows are held out of the timeline and mature on the presentation clock, which
    /// moves without a state publish, so they cannot be inferred from the generation alone.
    let scheduledMessageIDs: Set<UUID>

    init(stateGeneration: UInt64, conversationID: String, scheduledMessageIDs: Set<UUID>) {
        self.stateGeneration = stateGeneration
        self.conversationID = conversationID
        self.scheduledMessageIDs = scheduledMessageIDs
    }
}

/// Holds the last projection together with the key it was built from.
///
/// Returning the *same* value for an unchanged key is load-bearing beyond skipping the fold:
/// `Array`'s `==` short-circuits when both sides share one buffer, so SwiftUI's
/// `onChange(of: messages)` comparisons stop deep-comparing 2 000 messages — each carrying
/// optional attachment `Data` — on every render.
final class ConversationProjectionCache<Value> {
    private var key: ConversationProjectionKey?
    private var value: Value?
    /// How many times `build` actually ran. Tests assert on this; the app never reads it.
    private(set) var buildCount = 0

    init() {}

    /// The projection for `key`, folding only when this is not the key already held.
    func projection(for key: ConversationProjectionKey, build: () -> Value) -> Value {
        if let value, self.key == key { return value }
        let built = build()
        self.key = key
        value = built
        buildCount += 1
        return built
    }

    /// Drops the memo without waiting for a key change. An account teardown must not be able to
    /// answer a later read with the previous account's messages.
    func invalidate() {
        key = nil
        value = nil
    }
}
