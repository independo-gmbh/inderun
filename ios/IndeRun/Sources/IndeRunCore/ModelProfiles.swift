import Foundation
import IndeRunContracts

/// Why a model profile configuration was refused.
public struct ModelProfilesConfigurationError: Error, Sendable, CustomStringConvertible {
    public let description: String
}

/// Application-defined model profiles: a profile name mapped to an ordered list of
/// target ids (provider instance ids, each bound to one model).
///
/// Requests name a profile through `TaskRequest.modelProfile`; the route planner
/// treats the list as an allow-list and ranks its entries after placement and
/// before preferences. Ids that name no registered provider are ignored by the
/// planner. `"auto"` is built in -- every registered target -- and cannot be
/// redefined. See `docs/architecture/api-layering.md`.
public struct ModelProfiles: Sendable {
    /// The built-in profile name.
    public static let auto = "auto"

    /// No application-defined profiles; every request routes within `auto`.
    public static let none = ModelProfiles(validated: [:])

    private let profiles: [String: [String]]

    /// Validates the configuration once, so a malformed profile is a setup error
    /// rather than a per-request surprise.
    /// - Throws: `ModelProfilesConfigurationError` when a profile is named `auto`,
    ///   is empty, or lists a target twice.
    public init(_ profiles: [String: [String]]) throws {
        for (name, targetIds) in profiles {
            if name.isEmpty {
                throw ModelProfilesConfigurationError(description: "Model profile names must be non-empty.")
            }
            if name == Self.auto {
                throw ModelProfilesConfigurationError(
                    description: "\"\(Self.auto)\" is the built-in model profile and cannot be redefined."
                )
            }
            if targetIds.isEmpty {
                throw ModelProfilesConfigurationError(
                    description: "Model profile \"\(name)\" must list at least one target id."
                )
            }
            var seen = Set<String>()
            for id in targetIds {
                if id.isEmpty {
                    throw ModelProfilesConfigurationError(
                        description: "Model profile \"\(name)\" lists an empty target id."
                    )
                }
                if !seen.insert(id).inserted {
                    throw ModelProfilesConfigurationError(
                        description: "Model profile \"\(name)\" lists target \"\(id)\" more than once."
                    )
                }
            }
        }
        self.profiles = profiles
    }

    private init(validated profiles: [String: [String]]) {
        self.profiles = profiles
    }

    /// The outcome of looking a request's profile name up.
    public enum Resolution: Sendable {
        /// `auto`, or no profile named: route across every target.
        case auto
        /// A configured profile, as the shared planner consumes it.
        case profile(ModelProfile)
        /// The name matches no configured profile.
        case unknown
    }

    /// Resolves a request's profile name against the configured profiles.
    public func resolve(_ name: String?) -> Resolution {
        guard let name, name != Self.auto else { return .auto }
        guard let targetIds = profiles[name] else { return .unknown }
        return .profile(ModelProfile(name: name, targetIds: targetIds))
    }
}
