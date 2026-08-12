import Foundation

/// A downloadable ONNX text-generation model for the ONNX Local provider.
///
/// `SystemOnnxGenAiRuntime` (the SDK's default ONNX runtime) only supports plain decoder-only
/// graphs (`input_ids`/`attention_mask` in, `logits` out, no `past_key_values`), so the catalog
/// is limited to small base language models like this one until
/// https://github.com/independo-gmbh/inderun/issues/126 adds KV-cache support. Add more capable
/// instruction-tuned models here once that lands.
struct DemoOnnxModelOption: Identifiable, Hashable {
    struct RemoteFile: Hashable {
        /// Path within the Hugging Face repo.
        let repoPath: String
        /// Filename this is saved as locally; must match what `SystemOnnxGenAiRuntime` expects.
        let localFileName: String
        /// Approximate share of total download size, used to weight combined progress.
        let weight: Double
    }

    let id: String
    let title: String
    let huggingFaceRepo: String
    let files: [RemoteFile]

    static let distilgpt2Quantized = DemoOnnxModelOption(
        id: "distilgpt2-quantized",
        title: "DistilGPT-2 (quantized, ~84 MB)",
        huggingFaceRepo: "Xenova/distilgpt2",
        files: [
            RemoteFile(repoPath: "onnx/decoder_model_quantized.onnx", localFileName: "model.onnx", weight: 0.97),
            RemoteFile(repoPath: "tokenizer.json", localFileName: "tokenizer.json", weight: 0.025),
            RemoteFile(repoPath: "tokenizer_config.json", localFileName: "tokenizer_config.json", weight: 0.004),
            RemoteFile(repoPath: "config.json", localFileName: "config.json", weight: 0.001)
        ]
    )

    static let catalog: [DemoOnnxModelOption] = [distilgpt2Quantized]
}

/// User-facing selection for the ONNX Local provider, including the no-download fixture option.
enum DemoOnnxModelSelection: String, CaseIterable, Identifiable {
    case fixture
    case distilgpt2Quantized

    var id: String { rawValue }

    var title: String {
        switch self {
        case .fixture:
            return "Fixture (no download)"
        case .distilgpt2Quantized:
            return DemoOnnxModelOption.distilgpt2Quantized.title
        }
    }

    var modelOption: DemoOnnxModelOption? {
        switch self {
        case .fixture:
            return nil
        case .distilgpt2Quantized:
            return .distilgpt2Quantized
        }
    }
}

enum DemoOnnxDownloadState {
    case idle
    case downloading(progress: Double)
    case ready
    case failed(String)
}

enum DemoOnnxDownloadError: Error, LocalizedError {
    case invalidURL(String)
    case httpStatus(Int, String)

    var errorDescription: String? {
        switch self {
        case .invalidURL(let value):
            return "Invalid download URL: \(value)"
        case .httpStatus(let code, let url):
            return "Download failed with HTTP \(code) for \(url)"
        }
    }
}

/// Downloads a `DemoOnnxModelOption`'s files from Hugging Face into the app's Application
/// Support directory so the ONNX Local provider can run real on-device generation without any
/// manual setup, mirroring the web demo's automatic model download via `@huggingface/transformers`.
///
/// Progress is reported through a caller-supplied `Progress` (composed from each file's
/// `URLSessionTask.progress` via `addChild`), not closures, since `Progress` is safe to read
/// from any thread while this downloads on a background task -- avoiding the need to bounce
/// non-Sendable UI state across actor boundaries from inside a completion handler.
final class DemoOnnxModelDownloader: @unchecked Sendable {
    static let shared = DemoOnnxModelDownloader()

    private let fileManager = FileManager.default

    func localDirectory(for model: DemoOnnxModelOption) -> URL {
        let base = (try? fileManager.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? fileManager.temporaryDirectory
        return base
            .appendingPathComponent("inderun-demo-onnx-models", isDirectory: true)
            .appendingPathComponent(model.id, isDirectory: true)
    }

    func isDownloaded(_ model: DemoOnnxModelOption) -> Bool {
        let directory = localDirectory(for: model)
        return model.files.allSatisfy { fileManager.fileExists(atPath: directory.appendingPathComponent($0.localFileName).path) }
    }

    func download(_ model: DemoOnnxModelOption, into progress: Progress) async throws {
        let directory = localDirectory(for: model)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        for file in model.files {
            let unitCount = Int64(file.weight * 1000)
            let destination = directory.appendingPathComponent(file.localFileName)

            if fileManager.fileExists(atPath: destination.path) {
                progress.completedUnitCount += unitCount
                continue
            }

            guard let url = URL(string: "https://huggingface.co/\(model.huggingFaceRepo)/resolve/main/\(file.repoPath)") else {
                throw DemoOnnxDownloadError.invalidURL(file.repoPath)
            }

            let tempURL = try await downloadFile(url: url, parent: progress, pendingUnitCount: unitCount)
            _ = try? fileManager.removeItem(at: destination)
            try fileManager.moveItem(at: tempURL, to: destination)
        }
    }

    private func downloadFile(url: URL, parent: Progress, pendingUnitCount: Int64) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            let task = URLSession.shared.downloadTask(with: url) { location, response, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                guard let location,
                      let http = response as? HTTPURLResponse,
                      (200..<300).contains(http.statusCode) else {
                    let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
                    continuation.resume(throwing: DemoOnnxDownloadError.httpStatus(statusCode, url.absoluteString))
                    return
                }

                let stableLocation = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                do {
                    try FileManager.default.moveItem(at: location, to: stableLocation)
                    continuation.resume(returning: stableLocation)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
            parent.addChild(task.progress, withPendingUnitCount: pendingUnitCount)
            task.resume()
        }
    }
}
