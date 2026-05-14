import Foundation
import os

/// Pairs an ASR diarization speaker label (e.g. "0", "Speaker 1") with the
/// identity UUID of the face that has been visible alongside that label
/// continuously for a minimum dwell window. Session-only — bindings are not
/// persisted across launches.
///
/// Pure data + a small state machine so it can be unit-tested without any
/// Vision / camera dependencies.
final class SpeakerBinder {
    /// How long the (speakerLabel, identityID) pair must be observed
    /// continuously before we bind. 1 second matches the spec.
    static let dwellSeconds: TimeInterval = 1.0

    /// Active session bindings: speakerLabel → identity UUID.
    private(set) var bindings: [String: UUID] = [:]

    /// In-flight observations keyed by speakerLabel. Cleared on label change
    /// or when the candidate identity changes.
    private var pending: [String: (identity: UUID, firstSeen: Date)] = [:]

    private let logger = Logger(subsystem: "com.gimbal.controller", category: "SpeakerBinder")

    init() {}

    /// Observe a (speakerLabel, identityID) pair at `now`. When the same pair
    /// has been observed continuously for `dwellSeconds`, a binding is committed
    /// and the pending entry is cleared. Returns true if a NEW binding was just
    /// committed during this call (useful for tests / logging).
    @discardableResult
    func observe(speakerLabel: String, identityID: UUID, now: Date = Date()) -> Bool {
        // If already bound to the same identity, nothing to do.
        if let existing = bindings[speakerLabel], existing == identityID {
            return false
        }
        // Re-binding to a different identity: drop the old pending state.
        if let p = pending[speakerLabel], p.identity != identityID {
            pending[speakerLabel] = (identity: identityID, firstSeen: now)
            return false
        }
        // Start the dwell timer if this is the first sighting.
        guard let p = pending[speakerLabel] else {
            pending[speakerLabel] = (identity: identityID, firstSeen: now)
            return false
        }
        // Continued sighting — commit once the dwell threshold is crossed.
        if now.timeIntervalSince(p.firstSeen) >= Self.dwellSeconds {
            bindings[speakerLabel] = identityID
            pending.removeValue(forKey: speakerLabel)
            logger.info("BIND: speakerLabel=\(speakerLabel, privacy: .public) → identity=\(identityID, privacy: .public)")
            return true
        }
        return false
    }

    /// Clear the pending dwell for a label without committing.
    /// Call this when the candidate face leaves the frame.
    func resetPending(speakerLabel: String) {
        pending.removeValue(forKey: speakerLabel)
    }

    /// Look up the identity currently bound to a diarization label.
    func identity(for speakerLabel: String) -> UUID? {
        bindings[speakerLabel]
    }

    /// Drop any bindings whose identity is no longer present in `validIDs`.
    /// Used after an identity is forgotten so stale bindings don't linger.
    func reconcile(validIDs: Set<UUID>) {
        for (label, id) in bindings where !validIDs.contains(id) {
            bindings.removeValue(forKey: label)
            logger.info("BIND: dropped stale speakerLabel=\(label, privacy: .public) (identity forgotten)")
        }
        for (label, p) in pending where !validIDs.contains(p.identity) {
            pending.removeValue(forKey: label)
        }
    }

    /// Forget all bindings — used when the camera stops or scan resets.
    func reset() {
        bindings = [:]
        pending = [:]
    }
}
