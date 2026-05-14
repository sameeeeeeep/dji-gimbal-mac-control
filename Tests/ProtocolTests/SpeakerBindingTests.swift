import XCTest
@testable import GimbalController

/// Covers the SpeakerBinder dwell→commit lifecycle and reconciliation
/// against a "known identity" set (mirrors what CameraTracker passes from
/// FaceRecognizer.knownFaces after an identity is forgotten).
final class SpeakerBindingTests: XCTestCase {

    // MARK: - Dwell-then-commit

    func testObservingPairForLessThanDwellDoesNotBind() {
        let binder = SpeakerBinder()
        let id = UUID()
        let t0 = Date(timeIntervalSince1970: 1000)

        // First sighting starts the dwell window — no binding yet.
        let committed1 = binder.observe(speakerLabel: "0", identityID: id, now: t0)
        XCTAssertFalse(committed1, "first observation must not commit")
        XCTAssertNil(binder.identity(for: "0"))

        // Still under the 1 s threshold.
        let committed2 = binder.observe(speakerLabel: "0", identityID: id,
                                         now: t0.addingTimeInterval(0.5))
        XCTAssertFalse(committed2)
        XCTAssertNil(binder.identity(for: "0"))
    }

    func testContinuousObservationOver1sCommitsBinding() {
        let binder = SpeakerBinder()
        let id = UUID()
        let t0 = Date(timeIntervalSince1970: 2000)

        _ = binder.observe(speakerLabel: "0", identityID: id, now: t0)
        // At exactly the dwell threshold the binding commits.
        let committed = binder.observe(speakerLabel: "0", identityID: id,
                                        now: t0.addingTimeInterval(SpeakerBinder.dwellSeconds))
        XCTAssertTrue(committed, "binding should commit at dwell threshold")
        XCTAssertEqual(binder.identity(for: "0"), id)
    }

    func testRebindRequiresFreshDwell() {
        let binder = SpeakerBinder()
        let idA = UUID()
        let idB = UUID()
        let t0 = Date(timeIntervalSince1970: 3000)

        _ = binder.observe(speakerLabel: "1", identityID: idA, now: t0)
        _ = binder.observe(speakerLabel: "1", identityID: idA,
                            now: t0.addingTimeInterval(1.2))
        XCTAssertEqual(binder.identity(for: "1"), idA)

        // A different identity now claims the same label — the previous
        // binding stays in place until idB completes its own dwell.
        _ = binder.observe(speakerLabel: "1", identityID: idB,
                            now: t0.addingTimeInterval(1.3))
        XCTAssertEqual(binder.identity(for: "1"), idA, "binding shouldn't flip without a full dwell")

        // After idB has been observed continuously for >1s, it takes over.
        _ = binder.observe(speakerLabel: "1", identityID: idB,
                            now: t0.addingTimeInterval(2.5))
        XCTAssertEqual(binder.identity(for: "1"), idB)
    }

    func testResetPendingDropsInFlightDwell() {
        let binder = SpeakerBinder()
        let id = UUID()
        let t0 = Date(timeIntervalSince1970: 4000)

        _ = binder.observe(speakerLabel: "2", identityID: id, now: t0)
        binder.resetPending(speakerLabel: "2")

        // After reset, a second observation must restart the dwell — so even
        // crossing the original threshold immediately should not bind.
        let committed = binder.observe(speakerLabel: "2", identityID: id,
                                        now: t0.addingTimeInterval(SpeakerBinder.dwellSeconds))
        XCTAssertFalse(committed, "resetPending should restart the dwell window")
        XCTAssertNil(binder.identity(for: "2"))
    }

    // MARK: - Lookup

    func testIdentityLookupReturnsBoundUUID() {
        let binder = SpeakerBinder()
        let id = UUID()
        let t0 = Date()
        _ = binder.observe(speakerLabel: "0", identityID: id, now: t0)
        _ = binder.observe(speakerLabel: "0", identityID: id,
                            now: t0.addingTimeInterval(SpeakerBinder.dwellSeconds + 0.01))
        XCTAssertEqual(binder.identity(for: "0"), id)
        XCTAssertNil(binder.identity(for: "99"), "unknown labels return nil")
    }

    // MARK: - Forget / reconcile

    func testReconcileDropsBindingForForgottenIdentity() {
        let binder = SpeakerBinder()
        let kept    = UUID()
        let dropped = UUID()
        let t0 = Date()

        // Bind two labels.
        for label in ["0", "1"] {
            let id = (label == "0") ? kept : dropped
            _ = binder.observe(speakerLabel: label, identityID: id, now: t0)
            _ = binder.observe(speakerLabel: label, identityID: id,
                                now: t0.addingTimeInterval(SpeakerBinder.dwellSeconds + 0.01))
        }
        XCTAssertEqual(binder.identity(for: "0"), kept)
        XCTAssertEqual(binder.identity(for: "1"), dropped)

        // Simulate IdentityStore.forget(dropped): only `kept` remains valid.
        binder.reconcile(validIDs: [kept])

        XCTAssertEqual(binder.identity(for: "0"), kept, "valid binding survives reconcile")
        XCTAssertNil(binder.identity(for: "1"), "forgotten identity drops its binding")
    }

    func testResetClearsEverything() {
        let binder = SpeakerBinder()
        let id = UUID()
        let t0 = Date()
        _ = binder.observe(speakerLabel: "0", identityID: id, now: t0)
        _ = binder.observe(speakerLabel: "0", identityID: id,
                            now: t0.addingTimeInterval(SpeakerBinder.dwellSeconds + 0.01))
        XCTAssertNotNil(binder.identity(for: "0"))
        binder.reset()
        XCTAssertNil(binder.identity(for: "0"))
        XCTAssertTrue(binder.bindings.isEmpty)
    }
}
