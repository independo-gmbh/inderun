import CryptoKit
import Foundation

/// What the person accepts before a single byte is requested.
struct ConsentPrompt: Equatable, Sendable {
    let entryId: String
    let totalBytes: Int64
    /// One line per licence: the model's, its attribution, and each distinct voice licence.
    let licenses: [String]
}

enum NeuralDownloadResult: Equatable, Sendable {
    case installed
    case declined
}

/// A download failure with a message fit to show as is.
struct NeuralDownloadError: Error, LocalizedError, Equatable {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

struct NeuralTransportResponse: Sendable {
    let status: Int
    /// The URL the body came from after redirects.
    let finalURL: URL
    let body: AsyncThrowingStream<Data, Error>
    /// Ends the underlying request; the downloader calls it when it refuses a response without reading the body.
    var cancel: @Sendable () -> Void = {}
}

/// The one place the network is touched, so tests can count requests.
protocol NeuralTransport: Sendable {
    func open(_ url: URL) async throws -> NeuralTransportResponse
}

/// Where a download is written; tests swap it to simulate a full disk.
protocol NeuralFileSink: Sendable {
    func write(_ data: Data) throws
    func close() throws
}

/// `@unchecked Sendable`: the handle is created in `init` and only used by the one download that owns the sink, one call at a time.
final class FileHandleSink: NeuralFileSink, @unchecked Sendable {
    private let handle: FileHandle

    init(url: URL) throws {
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        handle = try FileHandle(forWritingTo: url)
    }

    func write(_ data: Data) throws { try handle.write(contentsOf: data) }
    func close() throws { try handle.close() }
}

/// What the lab view model needs from a downloader (a protocol so view-model tests need no disk).
protocol NeuralModelInstalling: Sendable {
    func isInstalled(_ entry: CatalogEntry) async -> Bool
    func download(
        _ entry: CatalogEntry,
        consent: @escaping @Sendable (ConsentPrompt) async -> Bool,
        onProgress: @escaping @Sendable (Int64, Int64) -> Void
    ) async throws -> NeuralDownloadResult
}

func consentPrompt(for entry: CatalogEntry) -> ConsentPrompt {
    var lines: [String] = []
    let restrictions = entry.license.restrictions.flatMap { $0 == "none" ? nil : $0 }
    lines.append((entry.license.spdx ?? "unspecified licence") + (restrictions.map { ": \($0)" } ?? ""))
    if let attribution = entry.license.attribution { lines.append(attribution) }
    for voice in entry.voices {
        let line = "\(voice.license.spdx ?? "voice licence"): \(voice.license.restrictions ?? "")"
        if !lines.contains(line) { lines.append(line) }
    }
    return ConsentPrompt(entryId: entry.id, totalBytes: entry.totalBytes, licenses: lines)
}

/// Installs every file of a catalog entry (weights and voices) under
/// `<root>/voices-lab/<id>/<version>/`, which is where an `app_managed` package resolves its `ref`
/// (`root` is Application Support). Nothing is created or requested before the person consents.
///
/// A file is streamed to `<name>.part`, hashed on the way, and only moved into place once its byte
/// count and sha256 match, so a half-written file is never accepted. A mismatch deletes the file
/// and fails with `checksum mismatch: <path>`; a failure leaves only verified files behind, so a
/// retry resumes by skipping them.
final class DemoNeuralModelDownloader: NeuralModelInstalling, Sendable {
    private let root: URL
    private let transport: any NeuralTransport
    private let makeSink: @Sendable (URL) throws -> any NeuralFileSink

    init(
        root: URL = .applicationSupportDirectory,
        transport: any NeuralTransport = URLSessionNeuralTransport(),
        makeSink: @escaping @Sendable (URL) throws -> any NeuralFileSink = { try FileHandleSink(url: $0) }
    ) {
        self.root = root
        self.transport = transport
        self.makeSink = makeSink
    }

    func directory(for entry: CatalogEntry) -> URL {
        root.appendingPathComponent(entry.ref, isDirectory: true)
    }

    /// Read-only: creates nothing. True when every file is present with its size and sha256.
    func isInstalled(_ entry: CatalogEntry) async -> Bool {
        guard entry.isInstallable else { return false }
        let directory = directory(for: entry)
        // A cancelled check (the lab was switched off) stops hashing and reports "not installed".
        return entry.allFiles.allSatisfy { !Task.isCancelled && isVerified(directory.appendingPathComponent($0.path), $0) }
    }

    func download(
        _ entry: CatalogEntry,
        consent: @escaping @Sendable (ConsentPrompt) async -> Bool,
        onProgress: @escaping @Sendable (Int64, Int64) -> Void
    ) async throws -> NeuralDownloadResult {
        let prompt = consentPrompt(for: entry)
        guard await consent(prompt) else { return .declined }
        let directory = directory(for: entry)
        var done: Int64 = 0
        for file in entry.allFiles {
            try Task.checkCancellation()
            let destination = directory.appendingPathComponent(file.path)
            if isVerified(destination, file) {
                done += file.bytes
                onProgress(done, prompt.totalBytes)
                continue
            }
            // A stale or half-written file is never kept; one that cannot be removed is overwritten below.
            try? FileManager.default.removeItem(at: destination)
            let base = done
            try await downloadFile(file, to: destination) { onProgress(base + $0, prompt.totalBytes) }
            done += file.bytes
        }
        return .installed
    }

    private func downloadFile(_ file: CatalogFile, to destination: URL, onBytes: @Sendable (Int64) -> Void) async throws {
        guard let url = URL(string: file.url), url.scheme == "https" else {
            throw NeuralDownloadError("refused a download that is not https: \(file.path)")
        }
        let response: NeuralTransportResponse
        do {
            response = try await transport.open(url)
        } catch {
            try Task.checkCancellation()
            throw NeuralDownloadError("download failed: \(file.path): \(error.localizedDescription)")
        }
        guard response.finalURL.scheme == "https" else {
            response.cancel()
            throw NeuralDownloadError("refused a redirect to a URL that is not https: \(file.path)")
        }
        guard (200..<300).contains(response.status) else {
            response.cancel()
            let published = url.host == "github.com" && response.status == 404
            throw NeuralDownloadError("\(published ? "asset not published yet" : "download failed") (HTTP \(response.status)): \(file.path)")
        }

        let parent = destination.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        } catch {
            throw storageFailure(file, error)
        }
        let part = parent.appendingPathComponent("\(destination.lastPathComponent).part")
        try? FileManager.default.removeItem(at: part)
        var finished = false
        defer { if !finished { try? FileManager.default.removeItem(at: part) } }

        let sink: any NeuralFileSink
        do {
            sink = try makeSink(part)
        } catch {
            throw storageFailure(file, error)
        }
        // FileHandle.close() throws on a second call, so only one path closes it.
        var closed = false
        defer { if !closed { try? sink.close() } }
        var hasher = SHA256()
        var received: Int64 = 0
        var lastReport: ContinuousClock.Instant?
        do {
            for try await chunk in response.body {
                try Task.checkCancellation()
                received += Int64(chunk.count)
                if received > file.bytes { break }
                hasher.update(data: chunk)
                do {
                    try sink.write(chunk)
                } catch {
                    throw storageFailure(file, error)
                }
                // The first chunk, then at most about ten updates a second; the last one is sent once the file is verified.
                if lastReport.map({ ContinuousClock.now - $0 >= .milliseconds(100) }) ?? true {
                    lastReport = ContinuousClock.now
                    onBytes(received)
                }
            }
        } catch let error as NeuralDownloadError {
            throw error
        } catch {
            try Task.checkCancellation()
            throw NeuralDownloadError("download failed: \(file.path): \(error.localizedDescription)")
        }
        // A cancelled stream ends quietly, which must not read as a short body.
        try Task.checkCancellation()
        closed = true
        do {
            try sink.close()
        } catch {
            throw storageFailure(file, error)
        }
        guard received == file.bytes, Self.hex(hasher.finalize()) == file.sha256 else {
            throw NeuralDownloadError("checksum mismatch: \(file.path)")
        }
        do {
            try FileManager.default.moveItem(at: part, to: destination)
        } catch {
            throw storageFailure(file, error)
        }
        finished = true
        onBytes(file.bytes)
    }

    /// Any IO failure while checking means "not verified", so the file is fetched again.
    private func isVerified(_ target: URL, _ file: CatalogFile) -> Bool {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: target.path),
              (attributes[.size] as? NSNumber)?.int64Value == file.bytes,
              let handle = try? FileHandle(forReadingFrom: target) else { return false }
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let chunk: Data?
            do {
                chunk = try handle.read(upToCount: 64 * 1024)
            } catch {
                return false
            }
            // nil is the end of the file.
            guard let chunk, !chunk.isEmpty, !Task.isCancelled else { break }
            hasher.update(data: chunk)
        }
        return Self.hex(hasher.finalize()) == file.sha256
    }

    private func storageFailure(_ file: CatalogFile, _ error: Error) -> NeuralDownloadError {
        let nsError = error as NSError
        let full = (nsError.domain == NSCocoaErrorDomain && nsError.code == NSFileWriteOutOfSpaceError)
            || (nsError.domain == NSPOSIXErrorDomain && nsError.code == Int(ENOSPC))
        if full {
            return NeuralDownloadError("not enough storage space to save \(file.path); free some space and try again")
        }
        return NeuralDownloadError("could not write \(file.path): \(error.localizedDescription)")
    }

    private static func hex(_ digest: SHA256.Digest) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }
}

/// Direct fetch of Hugging Face files and GitHub release assets (no proxy). `URLSession` follows
/// redirects, but only to https; the downloader checks the final URL again.
struct URLSessionNeuralTransport: NeuralTransport {
    /// Tests pass a configuration with a custom `URLProtocol`.
    var configuration: URLSessionConfiguration = .ephemeral
    var userAgent: String = "IndeRunDemo/\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0")"

    func open(_ url: URL) async throws -> NeuralTransportResponse {
        var request = URLRequest(url: url)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 60

        let collector = StreamCollector()
        let session = URLSession(configuration: configuration, delegate: collector, delegateQueue: nil)
        let task = session.dataTask(with: request)
        collector.body.onTermination = { _ in
            task.cancel()
            session.finishTasksAndInvalidate()
        }
        let response: URLResponse
        do {
            response = try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    collector.awaitResponse(continuation)
                    task.resume()
                }
            } onCancel: {
                task.cancel()
            }
        } catch {
            session.invalidateAndCancel()
            // Cancelling the task surfaces as URLError.cancelled; the caller asked for it.
            try Task.checkCancellation()
            throw error
        }
        guard let http = response as? HTTPURLResponse, let finalURL = http.url else {
            throw URLError(.badServerResponse)
        }
        return NeuralTransportResponse(status: http.statusCode, finalURL: finalURL, body: collector.stream, cancel: { task.cancel() })
    }
}

/// `@unchecked Sendable`: `pending`, `early` and `delivered` are only touched under `lock`; the
/// stream continuation is itself thread-safe; URLSession calls the delegate methods serially.
private final class StreamCollector: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    let stream: AsyncThrowingStream<Data, Error>
    let body: AsyncThrowingStream<Data, Error>.Continuation
    private let lock = NSLock()
    private var pending: CheckedContinuation<URLResponse, Error>?
    private var delivered = false
    /// A result that arrived before anyone waited for it (a task cancelled before `awaitResponse`).
    private var early: Result<URLResponse, Error>?

    override init() {
        (stream, body) = AsyncThrowingStream<Data, Error>.makeStream()
        super.init()
    }

    func awaitResponse(_ continuation: CheckedContinuation<URLResponse, Error>) {
        let ready: Result<URLResponse, Error>? = lock.withLock {
            if let early { return early }
            pending = continuation
            return nil
        }
        if let ready { continuation.resume(with: ready) }
    }

    private func deliver(_ result: Result<URLResponse, Error>) {
        let continuation: CheckedContinuation<URLResponse, Error>? = lock.withLock {
            guard !delivered else { return nil }
            delivered = true
            guard let waiting = pending else {
                early = result
                return nil
            }
            pending = nil
            return waiting
        }
        continuation?.resume(with: result)
    }

    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void
    ) {
        // Never follow a redirect off https: the 3xx answer then reads as a failed download.
        completionHandler(request.url?.scheme == "https" ? request : nil)
    }

    func urlSession(
        _ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        deliver(.success(response))
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        body.yield(data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        deliver(.failure(error ?? URLError(.badServerResponse)))
        body.finish(throwing: error)
    }
}
