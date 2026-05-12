import Foundation
import Vision
import os

/// One persisted identity — either a face crop or a full-frame "place".
/// `embedding` stores the raw bytes from `VNFeaturePrintObservation.data`;
/// `elementType`/`elementCount` lets us reinterpret them as a float vector
/// at match time. We can't rehydrate a real VNFeaturePrintObservation
/// (no public init from bytes), so distance is computed manually as L2 on
/// the float vector — which is what computeDistance does internally for
/// .float prints anyway.
struct Identity: Identifiable, Codable {
    let id: UUID
    var name: String?
    let embedding: Data
    let elementType: UInt
    let elementCount: Int
    let createdAt: Date
    var lastSeenAt: Date
    var sampleCount: Int
}

@MainActor
final class IdentityStore: ObservableObject {

    @Published private(set) var people: [Identity] = []
    @Published private(set) var places: [Identity] = []

    private let directory: URL
    private let logger = Logger(subsystem: "com.gimbal.controller", category: "IdentityStore")

    /// `directory` is overridable for tests. Production passes nil → Application Support.
    init(directory: URL? = nil) {
        if let directory {
            self.directory = directory
        } else {
            let support = FileManager.default.urls(for: .applicationSupportDirectory,
                                                   in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSTemporaryDirectory())
            self.directory = support.appendingPathComponent("GimbalController", isDirectory: true)
        }
        try? FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
        load()
    }

    // MARK: - Matching

    /// Returns the closest face below `threshold`, or nil. Mutates `lastSeenAt`
    /// + `sampleCount` on hit and writes through to disk.
    func matchFace(_ obs: VNFeaturePrintObservation, threshold: Float = 0.18) -> (Identity, Float)? {
        match(obs, in: \.people, threshold: threshold)
    }

    func matchPlace(_ obs: VNFeaturePrintObservation, threshold: Float = 0.20) -> (Identity, Float)? {
        match(obs, in: \.places, threshold: threshold)
    }

    private func match(_ obs: VNFeaturePrintObservation,
                       in keyPath: KeyPath<IdentityStore, [Identity]>,
                       threshold: Float) -> (Identity, Float)? {
        let isPlaces = keyPath == \IdentityStore.places
        let candidates = isPlaces ? places : people
        guard !candidates.isEmpty else { return nil }
        let queryVec = Self.floatVector(from: obs.data,
                                        elementType: obs.elementType.rawValue,
                                        count: obs.elementCount)
        guard !queryVec.isEmpty else { return nil }

        var best: (idx: Int, dist: Float)?
        for (i, ident) in candidates.enumerated() {
            let stored = Self.floatVector(from: ident.embedding,
                                          elementType: ident.elementType,
                                          count: ident.elementCount)
            guard stored.count == queryVec.count else { continue }
            let d = Self.euclidean(stored, queryVec)
            if best == nil || d < best!.dist { best = (i, d) }
        }
        guard let best, best.dist <= threshold else { return nil }

        // Update lastSeenAt + sampleCount
        if isPlaces {
            places[best.idx].lastSeenAt = Date()
            places[best.idx].sampleCount += 1
            let hit = places[best.idx]
            save()
            return (hit, best.dist)
        } else {
            people[best.idx].lastSeenAt = Date()
            people[best.idx].sampleCount += 1
            let hit = people[best.idx]
            save()
            return (hit, best.dist)
        }
    }

    // MARK: - Mutation

    @discardableResult
    func addFace(_ obs: VNFeaturePrintObservation, name: String? = nil) -> Identity {
        let ident = Self.makeIdentity(from: obs, name: name)
        people.append(ident)
        save()
        return ident
    }

    @discardableResult
    func addPlace(_ obs: VNFeaturePrintObservation, name: String? = nil) -> Identity {
        let ident = Self.makeIdentity(from: obs, name: name)
        places.append(ident)
        save()
        return ident
    }

    func rename(id: UUID, to newName: String?) {
        if let i = people.firstIndex(where: { $0.id == id }) {
            people[i].name = newName; save(); return
        }
        if let i = places.firstIndex(where: { $0.id == id }) {
            places[i].name = newName; save()
        }
    }

    func forget(id: UUID) {
        people.removeAll { $0.id == id }
        places.removeAll { $0.id == id }
        save()
    }

    // MARK: - Persistence

    private var peoplePath: URL { directory.appendingPathComponent("identities.json") }

    private struct OnDisk: Codable {
        var people: [Identity]
        var places: [Identity]
    }

    private func load() {
        guard let data = try? Data(contentsOf: peoplePath),
              let decoded = try? JSONDecoder().decode(OnDisk.self, from: data) else {
            return
        }
        people = decoded.people
        places = decoded.places
    }

    private func save() {
        let payload = OnDisk(people: people, places: places)
        do {
            let data = try JSONEncoder().encode(payload)
            try data.write(to: peoplePath, options: .atomic)
        } catch {
            logger.error("save failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Helpers

    private static func makeIdentity(from obs: VNFeaturePrintObservation,
                                     name: String?) -> Identity {
        Identity(
            id: UUID(),
            name: name,
            embedding: obs.data,
            elementType: obs.elementType.rawValue,
            elementCount: obs.elementCount,
            createdAt: Date(),
            lastSeenAt: Date(),
            sampleCount: 1
        )
    }

    /// Reinterpret persisted feature-print bytes as a [Float] vector. We only
    /// support .float prints — VNFeaturePrintObservation has historically
    /// returned float (1) for the standard model. If we ever see another
    /// element type the vector returns empty and the caller skips the entry.
    static func floatVector(from data: Data, elementType: UInt, count: Int) -> [Float] {
        // VNElementType.float == 1, VNElementType.double == 2
        guard elementType == 1 else { return [] }
        guard data.count == count * MemoryLayout<Float>.stride else { return [] }
        return data.withUnsafeBytes { raw -> [Float] in
            let buf = raw.bindMemory(to: Float.self)
            return Array(buf)
        }
    }

    static func euclidean(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count else { return .infinity }
        var sum: Float = 0
        for i in 0..<a.count {
            let d = a[i] - b[i]
            sum += d * d
        }
        return sum.squareRoot()
    }

    // MARK: - Test-only synthetic factory

    /// Test hook for building an Identity directly from a [Float] without going
    /// through Vision. internal so tests in the same package see it.
    internal static func makeSynthetic(vector: [Float], name: String? = nil) -> Identity {
        let data = vector.withUnsafeBufferPointer { Data(buffer: $0) }
        return Identity(
            id: UUID(),
            name: name,
            embedding: data,
            elementType: 1,           // .float
            elementCount: vector.count,
            createdAt: Date(),
            lastSeenAt: Date(),
            sampleCount: 1
        )
    }

    /// Test hook to push a synthetic identity into the people store and persist.
    internal func _addSyntheticFace(_ ident: Identity) {
        people.append(ident)
        save()
    }

    /// Test hook to match a raw float vector against people without needing a
    /// real VNFeaturePrintObservation.
    internal func _matchFaceVector(_ vec: [Float], threshold: Float) -> (Identity, Float)? {
        guard !people.isEmpty else { return nil }
        var best: (idx: Int, dist: Float)?
        for (i, ident) in people.enumerated() {
            let stored = Self.floatVector(from: ident.embedding,
                                          elementType: ident.elementType,
                                          count: ident.elementCount)
            guard stored.count == vec.count else { continue }
            let d = Self.euclidean(stored, vec)
            if best == nil || d < best!.dist { best = (i, d) }
        }
        guard let best, best.dist <= threshold else { return nil }
        people[best.idx].lastSeenAt = Date()
        people[best.idx].sampleCount += 1
        save()
        return (people[best.idx], best.dist)
    }
}
