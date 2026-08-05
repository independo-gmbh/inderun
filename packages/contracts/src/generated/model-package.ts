/* This file was generated from JSON Schema using quicktype. Do not edit by hand. */

/**
 * Provider-neutral descriptor for a developer-supplied/custom local model made available to
 * an IndeRun local-model provider family (for example, the ONNX Runtime family). It
 * describes model identity, format, task support, source, files, integrity, licensing, and
 * resource expectations. It is bootstrap/configuration metadata resolved before execution;
 * it is not part of the public TaskRequest/TaskResult surface, and it must not carry raw
 * secrets.
 */
export type ModelPackage = {
    /**
     * Files that make up the model package, expressed as source-relative names/paths. The
     * provider adapter and model source resolve these to concrete bytes per platform.
     */
    files?: Files;
    /**
     * Model packaging format the target runtime family must understand. 'onnx' is a plain ONNX
     * graph, 'ort' is an ONNX Runtime optimized/mobile format, 'genai' is an ONNX Runtime GenAI
     * model package.
     */
    format: Format;
    /**
     * Stable application-scoped identifier for the model package.
     */
    id: string;
    /**
     * Optional integrity metadata used to validate resolved files before load.
     */
    integrity?: Integrity;
    /**
     * Optional license/source metadata for the model, for developer transparency. Free-form.
     */
    license?: License;
    /**
     * Optional known resource expectations, used by capability checks to reject on constrained
     * devices before load.
     */
    limits?: Limits;
    /**
     * Optional runtime compatibility expectations. Fields are advisory hints for capability
     * checks; the provider adapter owns exact enforcement.
     */
    runtime?: Runtime;
    /**
     * Where the model files are obtained from. Availability of each source type is
     * platform-dependent; see the ONNX Runtime provider-family specification for the
     * per-platform support matrix.
     */
    source?: Source;
    /**
     * IndeRun task kinds this model package can serve (for example 'text_to_text'). Used by
     * dynamic capability checks and route matching.
     */
    tasks?: string[];
    /**
     * Optional application-defined version for the model package, used for cache invalidation
     * and compatibility checks.
     */
    version?: string;
    [property: string]: unknown;
}

/**
 * Files that make up the model package, expressed as source-relative names/paths. The
 * provider adapter and model source resolve these to concrete bytes per platform.
 */
export type Files = {
    /**
     * Optional model/generation config file, where the model requires one.
     */
    config?: string;
    /**
     * Optional external data files referenced by the model graph (for example ONNX external
     * weights).
     */
    external?: string[];
    /**
     * Files that must be present for the package to load (for example the model graph).
     */
    required?: string[];
    /**
     * Optional tokenizer file, where the model requires one.
     */
    tokenizer?: string;
    [property: string]: unknown;
}

/**
 * Model packaging format the target runtime family must understand. 'onnx' is a plain ONNX
 * graph, 'ort' is an ONNX Runtime optimized/mobile format, 'genai' is an ONNX Runtime GenAI
 * model package.
 */
export type Format = "onnx" | "ort" | "genai";

/**
 * Optional integrity metadata used to validate resolved files before load.
 */
export type Integrity = {
    /**
     * Map of file name to expected checksum (for example 'sha256:...'). Absence means integrity
     * is not verified by IndeRun.
     */
    checksums?: { [key: string]: string };
    [property: string]: unknown;
}

/**
 * Optional license/source metadata for the model, for developer transparency. Free-form.
 */
export type License = {
    /**
     * SPDX license identifier where known (for example 'Apache-2.0').
     */
    spdx?: string;
    /**
     * License or model card URL where available.
     */
    url?: string;
    [property: string]: unknown;
}

/**
 * Optional known resource expectations, used by capability checks to reject on constrained
 * devices before load.
 */
export type Limits = {
    /**
     * Approximate on-disk size of the resolved package, where known.
     */
    diskBytes?: number;
    /**
     * Approximate peak memory required to run the model, where known.
     */
    memBytes?: number;
    [property: string]: unknown;
}

/**
 * Optional runtime compatibility expectations. Fields are advisory hints for capability
 * checks; the provider adapter owns exact enforcement.
 */
export type Runtime = {
    /**
     * Minimum ONNX opset version the model requires, where known.
     */
    minOpset?: number;
    /**
     * Minimum runtime package version required to load the model, where known.
     */
    minRuntimeVersion?: string;
    /**
     * Platforms the package is expected to run on (for example 'web', 'android', 'apple').
     * Absence means unconstrained.
     */
    platforms?: string[];
    [property: string]: unknown;
}

/**
 * Where the model files are obtained from. Availability of each source type is
 * platform-dependent; see the ONNX Runtime provider-family specification for the
 * per-platform support matrix.
 */
export type Source = {
    /**
     * Optional source-specific reference (for example a registry repo id or a bundled asset
     * base path). Interpretation depends on 'sourceType'. Must not contain credentials: URL
     * userinfo (for example 'https://user:pass@host/...') is rejected, and credentials must be
     * supplied via authContextRef instead.
     */
    ref?: string;
    /**
     * Discriminator for how the host makes model files available. 'registry' is a web
     * repository/registry reference (for example a Hugging Face-style repo), 'bundled' is an
     * app asset/resource, 'programmatic' is supplied directly by application code, 'filesystem'
     * is a local path where the platform allows it, 'app_managed' is an app-managed
     * cache/storage location, 'remote' is a host-managed download.
     */
    sourceType: SourceType;
    [property: string]: unknown;
}

/**
 * Discriminator for how the host makes model files available. 'registry' is a web
 * repository/registry reference (for example a Hugging Face-style repo), 'bundled' is an
 * app asset/resource, 'programmatic' is supplied directly by application code, 'filesystem'
 * is a local path where the platform allows it, 'app_managed' is an app-managed
 * cache/storage location, 'remote' is a host-managed download.
 */
export type SourceType = "registry" | "bundled" | "programmatic" | "filesystem" | "app_managed" | "remote";
