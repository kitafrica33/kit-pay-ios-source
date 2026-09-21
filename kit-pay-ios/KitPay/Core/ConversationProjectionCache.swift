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

/// What one conversation *layout* derivation was computed from.
///
/// `ConversationProjectionKey` answers "are these the same messages?". This answers "would the
/// six whole-thread folds that turn those messages into rows produce the same rows?" — which
/// needs three more things the projection does not care about: whether the screen is in
/// selection mode (albums are broken up for it), who "you" are (reaction tallies mark your own),
/// whether this is a group (only groups head a run with a sender's name), and the calendar day,
/// because date separators say "Today" and stop being true at midnight.
struct ConversationLayoutKey: Equatable {
    let projection: ConversationProjectionKey
    let isSelectingMessages: Bool
    let isGroupConversation: Bool
    let currentUserID: String?
    /// Start of the day the separators were worded against.
    let separatorDay: Date
    /// Separator wording is localised; a locale change does not publish app state.
    let localeIdentifier: String

    init(
        projection: ConversationProjectionKey,
        isSelectingMessages: Bool,
        isGroupConversation: Bool,
        currentUserID: String?,
        separatorDay: Date,
        localeIdentifier: String
    ) {
        self.projection = projection
        self.isSelectingMessages = isSelectingMessages
        self.isGroupConversation = isGroupConversation
        self.currentUserID = currentUserID
        self.separatorDay = separatorDay
        self.localeIdentifier = localeIdentifier
    }
}

/// Holds the last layout derivation together with the key it was built from.
///
/// Deliberately a second type rather than a generic parameter on `ConversationProjectionCache`:
/// that cache's shape is pinned by its own gates, and the two are read at different points in
/// `body` for different reasons. What they share is the contract — fold only when the key
/// changes, hand back the *same* value otherwise, and never answer a changed key.
///
/// The derivations this holds are the six whole-thread folds `ConversationView.conversationLayout`
/// ran on every render after the projection memo landed: the timeline items (date separators and
/// call rows), album membership, the id index albums read, suppressed reaction rows, reaction
/// tallies, and which messages head a sender run. Each is O(every message in the thread), each
/// allocates, and all six ran while a finger was on the screen.
final class ConversationLayoutCache<Value> {
    private var key: ConversationLayoutKey?
    private var value: Value?
    /// How many times `build` actually ran. Tests assert on this; the app never reads it.
    private(set) var buildCount = 0

    init() {}

    /// The derivation for `key`, folding only when this is not the key already held.
    func derivation(for key: ConversationLayoutKey, build: () -> Value) -> Value {
        if let value, self.key == key { return value }
        let built = build()
        self.key = key
        value = built
        buildCount += 1
        return built
    }

    /// Drops the memo without waiting for a key change.
    func invalidate() {
        key = nil
        value = nil
    }
}
