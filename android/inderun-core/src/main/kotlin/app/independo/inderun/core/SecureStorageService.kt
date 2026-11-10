package app.independo.inderun.core

import android.content.Context

/**
 * Slot-based credential storage for values referenced through authContextRef.
 *
 * The engine keeps the storage surface normalized while this implementation uses
 * app-private preferences as the concrete Android backing store.
 */
class SecureStorageServiceImpl(context: Context) : SecureStorageService {
    private val preferences = context.getSharedPreferences(PREFERENCES_NAME, Context.MODE_PRIVATE)

    /**
     * {@inheritDoc}
     */
    override fun get(authContextRef: String): String? = preferences.getString(slotKey(authContextRef), null)

    override fun put(authContextRef: String, value: String) {
        preferences.edit().putString(slotKey(authContextRef), value).apply()
    }

    override fun remove(authContextRef: String) {
        preferences.edit().remove(slotKey(authContextRef)).apply()
    }

    private fun slotKey(authContextRef: String): String {
        require(authContextRef.isNotBlank()) { "authContextRef must not be blank." }
        return SLOT_PREFIX + authContextRef
    }

    private companion object {
        const val PREFERENCES_NAME = "app.independo.inderun.secure_storage"
        const val SLOT_PREFIX = "slot:"
    }
}
