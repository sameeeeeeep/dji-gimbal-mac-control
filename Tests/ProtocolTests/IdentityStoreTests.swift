import XCTest
@testable import GimbalController

@MainActor
final class IdentityStoreTests: XCTestCase {

    private var tempDir: URL!

    override func setUp() async throws {
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("IdentityStoreTests-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    // MARK: - Pure distance math

    func test_distance_identical_returns_zero() {
        let a: [Float] = [0.1, 0.2, 0.3, 0.4]
        let d = IdentityStore.euclidean(a, a)
        XCTAssertEqual(d, 0, accuracy: 1e-6)
    }

    func test_distance_grows_with_difference() {
        let a: [Float] = [0.0, 0.0, 0.0, 0.0]
        let small: [Float] = [0.1, 0.0, 0.0, 0.0]
        let big: [Float]   = [1.0, 0.0, 0.0, 0.0]
        let dSmall = IdentityStore.euclidean(a, small)
        let dBig   = IdentityStore.euclidean(a, big)
        XCTAssertGreaterThan(dSmall, 0)
        XCTAssertGreaterThan(dBig, dSmall)
    }

    // MARK: - Match flows

    func test_addFace_then_match_finds_it() {
        let store = IdentityStore(directory: tempDir)
        let vec: [Float] = [0.1, 0.2, 0.3, 0.4, 0.5]
        let synth = IdentityStore.makeSynthetic(vector: vec, name: "Sameep")
        store._addSyntheticFace(synth)

        let hit = store._matchFaceVector(vec, threshold: 0.18)
        XCTAssertNotNil(hit)
        XCTAssertEqual(hit?.0.name, "Sameep")
        XCTAssertEqual(hit?.1 ?? 1, 0, accuracy: 1e-6)
    }

    func test_match_below_threshold_misses() {
        let store = IdentityStore(directory: tempDir)
        let vec: [Float] = [0.0, 0.0, 0.0, 0.0]
        let synth = IdentityStore.makeSynthetic(vector: vec, name: "A")
        store._addSyntheticFace(synth)

        // Far-away vector → distance well above 0.18
        let other: [Float] = [1.0, 1.0, 1.0, 1.0]
        XCTAssertNil(store._matchFaceVector(other, threshold: 0.18))
    }

    func test_rename_updates_name() {
        let store = IdentityStore(directory: tempDir)
        let synth = IdentityStore.makeSynthetic(vector: [0.1, 0.2], name: "tmp")
        store._addSyntheticFace(synth)
        let id = store.people.first!.id

        store.rename(id: id, to: "Sameep")
        XCTAssertEqual(store.people.first?.name, "Sameep")
    }

    func test_forget_removes_identity() {
        let store = IdentityStore(directory: tempDir)
        let synth = IdentityStore.makeSynthetic(vector: [0.1, 0.2])
        store._addSyntheticFace(synth)
        let id = store.people.first!.id

        store.forget(id: id)
        XCTAssertTrue(store.people.isEmpty)
    }

    func test_persistence_roundtrip() {
        let id: UUID
        let name: String? = "Sameep"
        do {
            let store = IdentityStore(directory: tempDir)
            let synth = IdentityStore.makeSynthetic(vector: [0.1, 0.2, 0.3], name: name)
            store._addSyntheticFace(synth)
            id = store.people.first!.id
        }
        // Fresh instance, same directory
        let reloaded = IdentityStore(directory: tempDir)
        XCTAssertEqual(reloaded.people.count, 1)
        XCTAssertEqual(reloaded.people.first?.id, id)
        XCTAssertEqual(reloaded.people.first?.name, name)
    }
}
