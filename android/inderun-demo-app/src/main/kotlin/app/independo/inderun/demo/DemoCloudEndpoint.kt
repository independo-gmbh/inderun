package app.independo.inderun.demo

import java.net.URL

internal const val DEMO_PROXY_PATH = "/api/inderun/openai-responses"

internal fun isValidEndpointUrl(endpointUrl: String): Boolean {
    val url = runCatching { URL(endpointUrl) }.getOrNull() ?: return false
    return (url.protocol == "http" || url.protocol == "https") && url.host.isNotBlank()
}

internal fun createProbeUrl(endpointUrl: String): String {
    val url = runCatching { URL(endpointUrl) }.getOrNull() ?: return endpointUrl
    if (url.path != DEMO_PROXY_PATH) {
        return endpointUrl
    }

    val port = if (url.port == -1) url.defaultPort else url.port
    return URL(url.protocol, url.host, port, "/health").toString()
}

internal fun unavailableCloudMessage(endpointUrl: String): String {
    val url = runCatching { URL(endpointUrl) }.getOrNull()
    if (url != null) {
        val host = url.host.lowercase()
        val port = if (url.port == -1) url.defaultPort else url.port
        if (url.path == DEMO_PROXY_PATH &&
            port == 8787 &&
            (host == "10.0.2.2" || host == "127.0.0.1" || host == "localhost")
        ) {
            return "Could not reach the local demo proxy at $endpointUrl. Start `pnpm --filter @independo/inderun-demo-proxy dev` or change the endpoint URL."
        }
    }

    return "Could not reach the configured cloud endpoint at $endpointUrl. Check the URL, port, server process, and network path."
}
