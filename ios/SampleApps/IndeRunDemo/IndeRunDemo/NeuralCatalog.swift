import Foundation
import IndeRunAppleProviders
import IndeRunContracts
import IndeRunOnnxProviders

// The demo's view of contracts/fixtures/speech/neural-model-catalog.json (#260). The shape is pinned
// by packages/contracts/src/neural-model-catalog.test.ts; catalogEntryToModelPackage is pinned by the
// shared catalog-to-package.json fixture, which IndeRunDemoTests runs against this implementation.

struct CatalogFile: Equatable, Sendable {
    let role: String?
    let path: String
    let url: String
    let sha256: String
    let bytes: Int64
}

/// A licence as the catalog states it. The SDK's `License` keeps only `spdx` and `url`; the demo shows all of it.
struct CatalogLicense: Equatable, Sendable {
    let spdx: String?
    let url: String?
    let restrictions: String?
    let attribution: String?
}

struct CatalogVoice: Equatable, Sendable {
    let id: String
    let name: String
    let locales: [String]
    let gender: String?
    let file: CatalogFile
    let license: CatalogLicense
}

struct CatalogEntry: Equatable, Sendable, Identifiable {
    let id: String
    let variant: String
    let version: String
    let license: CatalogLicense
    let reviewStatus: String
    let reviewNotes: String?
    let runtimeFormat: String
    let minOsVersion: String?
    let speechPipeline: String
    let sampleRate: Int
    let channels: Int
    let graphs: [String: String]
    let frontendKind: String
    let frontendAssets: [String: String]
    let files: [CatalogFile]
    let voices: [CatalogVoice]

    /// An entry the demo can download: it has files and is not left to a manual install.
    var isInstallable: Bool { reviewStatus != "manual_install" && !files.isEmpty }

    /// Every file of the entry, weights first, then each voice bundle.
    var allFiles: [CatalogFile] { files + voices.map(\.file) }

    var totalBytes: Int64 { allFiles.reduce(0) { $0 + $1.bytes } }

    /// Directory relative to Application Support: `voices-lab/<id>/<version>`.
    var ref: String { "voices-lab/\(id)/\(version)" }
}

enum NeuralCatalogParser {
    private struct Raw: Decodable {
        struct Review: Decodable { let status: String; let notes: String? }
        struct Runtime: Decodable { let format: String; let minOsVersion: String? }
        struct Frontend: Decodable { let kind: String; let assets: [String: String] }
        struct Speech: Decodable {
            let pipeline: String
            let sampleRate: Int
            let channels: Int
            let graphs: [String: String]
            let frontend: Frontend
        }
        struct License: Decodable { let spdx: String?; let url: String?; let restrictions: String?; let attribution: String? }
        struct File: Decodable { let role: String?; let path: String; let url: String; let sha256: String; let bytes: Int64 }
        struct Voice: Decodable {
            let id: String
            let name: String
            let locales: [String]
            let gender: String?
            let file: File
            let license: License
        }

        let id: String
        let variant: String
        let version: String
        let license: License
        let review: Review
        let runtime: Runtime
        let speech: Speech
        let files: [File]?
        let voices: [Voice]?
    }

    private struct Root: Decodable { let entries: [Raw] }

    static func parse(_ data: Data) throws -> [CatalogEntry] {
        try JSONDecoder().decode(Root.self, from: data).entries.map(entry)
    }

    private static func entry(_ raw: Raw) -> CatalogEntry {
        CatalogEntry(
            id: raw.id, variant: raw.variant, version: raw.version, license: license(raw.license),
            reviewStatus: raw.review.status, reviewNotes: raw.review.notes,
            runtimeFormat: raw.runtime.format, minOsVersion: raw.runtime.minOsVersion,
            speechPipeline: raw.speech.pipeline, sampleRate: raw.speech.sampleRate, channels: raw.speech.channels,
            graphs: raw.speech.graphs, frontendKind: raw.speech.frontend.kind, frontendAssets: raw.speech.frontend.assets,
            files: (raw.files ?? []).map(file),
            voices: (raw.voices ?? []).map { voice in
                CatalogVoice(
                    id: voice.id, name: voice.name, locales: voice.locales, gender: voice.gender,
                    file: file(voice.file), license: license(voice.license)
                )
            }
        )
    }

    private static func file(_ raw: Raw.File) -> CatalogFile {
        CatalogFile(role: raw.role, path: raw.path, url: raw.url, sha256: raw.sha256, bytes: raw.bytes)
    }

    private static func license(_ raw: Raw.License) -> CatalogLicense {
        CatalogLicense(spdx: raw.spdx, url: raw.url, restrictions: raw.restrictions, attribution: raw.attribution)
    }
}

struct NeuralCatalogError: Error, CustomStringConvertible {
    let description: String
}

/// Turns an installed entry into the `ModelPackage` the neural speech provider takes: `app_managed`
/// at `ref`, with `integrity.checksums` keyed by package path. The licence keeps `spdx` and `url`
/// (the contract has no field for `restrictions` or `attribution`).
func catalogEntryToModelPackage(_ entry: CatalogEntry, ref: String) throws -> ModelPackage {
    guard let format = Format(rawValue: entry.runtimeFormat) else {
        throw NeuralCatalogError(description: "unknown format \(entry.runtimeFormat)")
    }
    guard let frontendKind = FrontendKind(rawValue: entry.frontendKind) else {
        throw NeuralCatalogError(description: "unknown frontend kind \(entry.frontendKind)")
    }
    let checksums = Dictionary(entry.allFiles.map { ($0.path, "sha256:\($0.sha256)") }, uniquingKeysWith: { _, last in last })
    return ModelPackage(
        files: nil,
        format: format,
        id: entry.id,
        integrity: Integrity(checksums: checksums),
        license: License(spdx: entry.license.spdx, url: entry.license.url),
        limits: nil,
        runtime: entry.minOsVersion.map { Runtime(minOpset: nil, minOsVersion: $0, minRuntimeVersion: nil, platforms: nil) },
        source: Source(ref: ref, sourceType: .appManaged),
        speech: SpeechModelPackage(
            channels: entry.channels,
            frontend: SpeechFrontend(assets: entry.frontendAssets, kind: frontendKind, license: nil),
            graphs: entry.graphs,
            pipeline: entry.speechPipeline,
            sampleRate: entry.sampleRate,
            voices: entry.voices.map { voice in
                SpeechModelVoice(
                    file: voice.file.path,
                    gender: voice.gender.flatMap(VoiceGender.init(rawValue:)),
                    id: voice.id,
                    license: AssetLicense(spdx: voice.license.spdx, url: voice.license.url),
                    locales: voice.locales,
                    name: voice.name
                )
            }
        ),
        tasks: ["text_to_speech"],
        variant: entry.variant,
        version: entry.version
    )
}

/// Provider id the Apple neural speech provider takes for a package: `<default id>:<package id>`.
func neuralProviderId(_ entryId: String) -> String { "\(NeuralSpeechProvider.defaultId):\(entryId)" }

/// The model profile requests name to reach an installed entry (never a model id).
func labProfileName(_ entryId: String) -> String { "voices-lab:\(entryId)" }

/// The profile of the OS voice alone: the A/B control.
let labControlProfile = "voices-lab:control"

/// The lab's profiles: per installed entry, `[neural provider, Apple system speech]`.
func voicesLabProfiles(installedEntryIds: [String]) -> [String: [String]] {
    Dictionary(uniqueKeysWithValues: installedEntryIds.map {
        (labProfileName($0), [neuralProviderId($0), AppleSystemSpeechProvider.defaultId])
    })
}
