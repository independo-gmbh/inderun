import Foundation
import IndeRunContracts

// MARK: - Limits and chunks

/// Size limits of an engine's artifact store (ADR 017). Every limit is in bytes.
public struct ArtifactLimits: Sendable, Equatable {
    /// Largest single artifact a provider may write. Default 16 MiB.
    public var maxArtifactBytes: Int
    /// Most bytes the store holds across all undisposed artifacts. Default 64 MiB.
    public var maxStoreBytes: Int
    /// Most bytes one `readArtifact` call returns. Default 1 MiB.
    public var maxReadBytes: Int

    public init(
        maxArtifactBytes: Int = 16 * 1024 * 1024,
        maxStoreBytes: Int = 64 * 1024 * 1024,
        maxReadBytes: Int = 1024 * 1024
    ) {
        self.maxArtifactBytes = maxArtifactBytes
        self.maxStoreBytes = maxStoreBytes
        self.maxReadBytes = maxReadBytes
    }
}

/// One range of an artifact's bytes, as `IndeRun.readArtifact` returns it.
public struct ArtifactChunk: Sendable, Equatable {
    /// The artifact the bytes belong to.
    public let artifactId: String
    /// Byte offset of `bytes` within the artifact.
    public let offset: Int
    /// The bytes of this range; empty when `offset` is the artifact's end.
    public let bytes: Data
    /// Size of the whole artifact in bytes.
    public let totalBytes: Int
    /// Whether this range reaches the end of the artifact.
    public let done: Bool

    public init(artifactId: String, offset: Int, bytes: Data, totalBytes: Int, done: Bool) {
        self.artifactId = artifactId
        self.offset = offset
        self.bytes = bytes
        self.totalBytes = totalBytes
        self.done = done
    }
}

// MARK: - Provider-facing contract

/// What a provider declares when it starts writing an artifact.
public struct ArtifactSpec: Sendable, Equatable {
    /// IANA media type of the bytes, e.g. `audio/wav`; parameters ride on it.
    public var mediaType: String
    /// Duration of time-based media in milliseconds, where the provider knows it.
    public var durationMs: Double?

    public init(mediaType: String, durationMs: Double? = nil) {
        self.mediaType = mediaType
        self.durationMs = durationMs
    }
}

/// Writes one artifact into the engine's store. ``finish()`` hands it over: it commits the run
/// to the provider and returns the reference the provider puts in its output. A provider that
/// fails or stops before ``finish()`` calls ``abort()``; the engine also discards any writer an
/// attempt left open.
public protocol ArtifactWriter: AnyObject, Sendable {
    /// Appends bytes. Throws `Unavailable` (`details.code: "artifact_too_large"`) once the
    /// artifact would exceed the engine's per-artifact limit; the attempt has not committed,
    /// so the run may fall back.
    func write(_ bytes: Data) throws
    /// Hands the finished artifact to the engine and commits the run. Throws `Unavailable`
    /// (`artifact_store_full`) when the store has no room, and `Unavailable`
    /// (`run_not_active`) when the run was cancelled or has ended -- in both cases before
    /// committing.
    func finish() throws -> MediaArtifact
    /// Discards everything written. Idempotent.
    func abort()
}

/// Where a provider creates artifacts: `RunContext.artifacts` and
/// `ProviderStreamContext.artifacts`.
public protocol ArtifactSink: Sendable {
    func create(spec: ArtifactSpec) -> any ArtifactWriter
}

// MARK: - Store

/// The engine-owned, in-memory artifact store (ADR 017): one per `IndeRun` instance. It holds
/// every finished artifact until the application disposes it; there are no temporary files,
/// so nothing outlives the process. Reads are ranged and bounded by `maxReadBytes`.
///
/// Locked: providers may write and finish from tasks of their own while the application reads
/// and disposes from others.
public final class ArtifactStore: @unchecked Sendable {
    private struct Stored {
        let reference: MediaArtifact
        let bytes: Data
    }

    public let limits: ArtifactLimits
    private let lock = NSLock()
    private var artifacts: [String: Stored] = [:]
    private var storedBytes = 0

    public init(limits: ArtifactLimits = ArtifactLimits()) {
        self.limits = limits
    }

    /// Opens the artifacts of one attempt. `commit` is the attempt's commit hook; a writer's
    /// `finish()` calls it, and refuses the handoff when it returns `false`.
    public func attempt(commit: @escaping @Sendable () -> Bool) -> AttemptArtifacts {
        AttemptArtifacts(store: self, commit: commit)
    }

    /// Reads one range. See `IndeRunApi.readArtifact` for the contract; the request's own
    /// shape (non-empty id, non-negative offset, positive `maxBytes`) is the caller's to check.
    public func read(_ request: ArtifactReadRequest) throws -> ArtifactChunk {
        let stored = lock.locked { artifacts[request.artifactId] }
        guard let stored else {
            throw createUnavailable(
                message: "Artifact '\(request.artifactId)' is not held by this engine.",
                retryable: false,
                details: ["code": JSONAny("artifact_not_found")]
            )
        }
        let totalBytes = stored.bytes.count
        let offset = request.offset ?? 0
        if offset > totalBytes {
            throw artifactReadValidationFailure([
                (path: "/offset", message: "offset \(offset) is beyond the artifact's \(totalBytes) bytes")
            ])
        }
        let length = min(request.maxBytes ?? limits.maxReadBytes, limits.maxReadBytes)
        let end = min(offset + length, totalBytes)
        let start = stored.bytes.startIndex
        return ArtifactChunk(
            artifactId: request.artifactId,
            offset: offset,
            // A copy: the caller may keep it without holding on to the whole stored artifact.
            bytes: Data(stored.bytes[(start + offset) ..< (start + end)]),
            totalBytes: totalBytes,
            done: end == totalBytes
        )
    }

    /// Releases an artifact's bytes. Idempotent; unknown ids are ignored.
    public func dispose(artifactId: String) {
        lock.locked {
            guard let stored = artifacts.removeValue(forKey: artifactId) else { return }
            storedBytes -= stored.bytes.count
        }
    }

    /// The whole artifact, for writing it to an application destination; `nil` once it was
    /// disposed.
    public func bytes(artifactId: String) -> Data? {
        lock.locked { artifacts[artifactId]?.bytes }
    }

    /// The stored reference for `artifactId`, or `nil` once it was disposed.
    public func reference(artifactId: String) -> MediaArtifact? {
        lock.locked { artifacts[artifactId]?.reference }
    }

    /// Registers a finished artifact.
    fileprivate func store(spec: ArtifactSpec, bytes: Data) throws -> MediaArtifact {
        try lock.locked {
            if storedBytes + bytes.count > limits.maxStoreBytes {
                throw createUnavailable(
                    message: "The engine's artifact store is full; dispose artifacts to free it.",
                    details: ["code": JSONAny("artifact_store_full")]
                )
            }
            let reference = MediaArtifact(
                byteLength: bytes.count,
                destinationRef: nil,
                durationMs: spec.durationMs,
                id: "art_\(randomHex(byteCount: 12))",
                lifetime: .untilDisposed,
                mediaType: spec.mediaType,
                owner: .engine
            )
            artifacts[reference.id] = Stored(reference: reference, bytes: bytes)
            storedBytes += bytes.count
            return reference
        }
    }
}

// MARK: - Attempt

/// The artifacts one attempt created. The engine keeps the one the attempt returned and
/// releases the rest: everything from an attempt that failed, was cancelled or lost to
/// fallback, and anything a winning attempt finished but did not return. A returned artifact
/// is never released behind the application's back.
///
/// Once released, the attempt refuses further handoffs (`run_not_active`), so a provider
/// finishing from its own task after the engine moved on cannot leave an artifact nobody owns.
public final class AttemptArtifacts: ArtifactSink, @unchecked Sendable {
    private let store: ArtifactStore
    private let commit: @Sendable () -> Bool
    private let lock = NSLock()
    private var finished: Set<String> = []
    private var open: [ObjectIdentifier: AttemptArtifactWriter] = [:]
    private var released = false

    fileprivate init(store: ArtifactStore, commit: @escaping @Sendable () -> Bool) {
        self.store = store
        self.commit = commit
    }

    public func create(spec: ArtifactSpec) -> any ArtifactWriter {
        let writer = AttemptArtifactWriter(attempt: self, spec: spec)
        lock.locked { open[ObjectIdentifier(writer)] = writer }
        return writer
    }

    /// Whether `artifactId` was finished by this attempt and is still held.
    public func owns(artifactId: String) -> Bool {
        lock.locked { finished.contains(artifactId) } && store.reference(artifactId: artifactId) != nil
    }

    /// Releases every artifact of this attempt except `keep`, and closes open writers.
    /// Idempotent.
    public func release(keeping keep: String? = nil) {
        let (writers, ids) = lock.locked { () -> ([AttemptArtifactWriter], Set<String>) in
            released = true
            let snapshot = (Array(open.values), finished)
            finished = []
            return snapshot
        }
        for writer in writers { writer.abort() }
        for id in ids where id != keep {
            store.dispose(artifactId: id)
        }
    }

    fileprivate var maxArtifactBytes: Int { store.limits.maxArtifactBytes }

    fileprivate func closed(_ writer: AttemptArtifactWriter) {
        lock.locked { _ = open.removeValue(forKey: ObjectIdentifier(writer)) }
    }

    /// Stores `bytes` and commits the run. Stored before the commit so a full store fails the
    /// attempt pre-commit; dropped again when the run refuses the commit.
    fileprivate func handOver(spec: ArtifactSpec, bytes: Data) throws -> MediaArtifact {
        let reference = try store.store(spec: spec, bytes: bytes)
        let accepted = commit() && lock.locked { () -> Bool in
            if released { return false }
            finished.insert(reference.id)
            return true
        }
        if !accepted {
            store.dispose(artifactId: reference.id)
            throw createUnavailable(
                message: "The run is no longer active; the artifact was discarded.",
                details: ["code": JSONAny("run_not_active")]
            )
        }
        return reference
    }
}

/// The writer `AttemptArtifacts.create(spec:)` hands out. Locked like the rest of the store,
/// because the engine may abort it from the task driving the run while the provider writes.
private final class AttemptArtifactWriter: ArtifactWriter, @unchecked Sendable {
    private weak var attempt: AttemptArtifacts?
    private let spec: ArtifactSpec
    private let maxBytes: Int
    private let lock = NSLock()
    private var buffer = Data()
    private var isClosed = false

    init(attempt: AttemptArtifacts, spec: ArtifactSpec) {
        self.attempt = attempt
        self.spec = spec
        self.maxBytes = attempt.maxArtifactBytes
    }

    func write(_ bytes: Data) throws {
        enum Outcome { case written, closed, tooLarge }
        let outcome = lock.locked { () -> Outcome in
            if isClosed { return .closed }
            if buffer.count + bytes.count > maxBytes { return .tooLarge }
            buffer.append(bytes)
            return .written
        }
        switch outcome {
        case .written:
            return
        case .closed:
            throw createInternal(message: "The artifact writer is already closed.")
        case .tooLarge:
            abort()
            throw createUnavailable(
                message: "The artifact exceeds the engine's \(maxBytes)-byte limit.",
                details: ["code": JSONAny("artifact_too_large")]
            )
        }
    }

    func finish() throws -> MediaArtifact {
        guard let bytes = close() else {
            throw createInternal(message: "The artifact writer is already closed.")
        }
        guard let attempt else {
            throw createUnavailable(
                message: "The run is no longer active; the artifact was discarded.",
                details: ["code": JSONAny("run_not_active")]
            )
        }
        return try attempt.handOver(spec: spec, bytes: bytes)
    }

    func abort() {
        _ = close()
    }

    /// Closes the writer; returns what it held if it was still open, so exactly one `finish()`
    /// gets the bytes.
    private func close() -> Data? {
        let bytes = lock.locked { () -> Data? in
            defer {
                isClosed = true
                buffer = Data()
            }
            return isClosed ? nil : buffer
        }
        attempt?.closed(self)
        return bytes
    }
}

// MARK: - Helpers

/// The `Internal` validation error `readArtifact` throws, in the shape the Web SDK reports for
/// an `ArtifactReadRequest`: one `{ path, message }` per issue under `details.validationIssues`.
package func artifactReadValidationFailure(_ issues: [(path: String, message: String)]) -> IndeRunException {
    createInternal(
        message: "Validation failed for ArtifactReadRequest: "
            + issues.map { "\($0.path) - \($0.message)" }.joined(separator: "; "),
        details: ["validationIssues": JSONAny(issues.map { ["path": $0.path, "message": $0.message] })]
    )
}

private extension NSLock {
    func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}

private func randomHex(byteCount: Int) -> String {
    var generator = SystemRandomNumberGenerator()
    return (0 ..< byteCount)
        .map { _ in String(format: "%02x", UInt8.random(in: .min ... .max, using: &generator)) }
        .joined()
}
