package app.independo.inderun.core

import app.independo.inderun.contracts.ModelProfile

/**
 * Application-defined model profiles: a profile name mapped to an ordered list of target ids
 * (provider instance ids, each bound to one model).
 *
 * Requests name a profile through `TaskRequest.modelProfile`; the route planner treats the list
 * as an allow-list and ranks its entries after placement and before preferences. Ids that name
 * no registered provider are ignored by the planner. [AUTO] is built in -- every registered
 * target -- and cannot be redefined. See `docs/architecture/api-layering.md`.
 *
 * The configuration is validated once, here, so a malformed profile is a setup error rather
 * than a per-request surprise.
 *
 * @throws IllegalArgumentException when a profile is named [AUTO], is empty, or lists a target
 *   twice.
 */
class ModelProfiles(profiles: Map<String, List<String>> = emptyMap()) {
    private val profiles: Map<String, List<String>> = profiles.mapValues { (_, ids) -> ids.toList() }

    init {
        for ((name, targetIds) in this.profiles) {
            require(name.isNotEmpty()) { "Model profile names must be non-empty." }
            require(name != AUTO) { "\"$AUTO\" is the built-in model profile and cannot be redefined." }
            require(targetIds.isNotEmpty()) { "Model profile \"$name\" must list at least one target id." }
            require(targetIds.none { it.isEmpty() }) { "Model profile \"$name\" lists an empty target id." }
            val duplicate = targetIds.groupingBy { it }.eachCount().entries.firstOrNull { it.value > 1 }
            require(duplicate == null) { "Model profile \"$name\" lists target \"${duplicate?.key}\" more than once." }
        }
    }

    /** The outcome of looking a request's profile name up. */
    sealed interface Resolution {
        /** `auto`, or no profile named: route across every target. */
        data object Auto : Resolution

        /** A configured profile, as the shared planner consumes it. */
        data class Profile(val profile: ModelProfile) : Resolution

        /** The name matches no configured profile. */
        data object Unknown : Resolution
    }

    /** Resolves a request's profile name against the configured profiles. */
    fun resolve(name: String?): Resolution {
        if (name == null || name == AUTO) return Resolution.Auto
        val targetIds = profiles[name] ?: return Resolution.Unknown
        return Resolution.Profile(ModelProfile(name = name, targetIds = targetIds))
    }

    companion object {
        /** The built-in profile name. */
        const val AUTO = "auto"
    }
}
