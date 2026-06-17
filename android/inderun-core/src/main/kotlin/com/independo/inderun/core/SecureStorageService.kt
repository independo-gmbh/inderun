package com.independo.inderun.core

import android.content.Context
import androidx.core.content.edit

/**
 * Slot-based credential storage for values referenced through authContextRef.
 *
 * This milestone keeps the storage surface normalized for the engine while using
 * app-private preferences as the concrete Android backing store.
 */
class SecureStorageServiceImpl(context: Context) : SecureStorageService {
    private val preferences = context.getSharedPreferences(PREFERENCES_NAME, Context.MODE_PRIVATE)

    /**
     * {@inheritDoc}
     */
    override fun get(authContextRef: String): String? {
        return preferences.getString(slotKey(authContextRef), null)
    }

    override fun put(authContextRef: String, value: String) {
        preferences.edit {
            putString(slotKey(authContextRef), value)
        }
    }

    override fun remove(authContextRef: String) {
        preferences.edit {
            remove(slotKey(authContextRef))
        }
    }

    private fun slotKey(authContextRef: String): String {
        require(authContextRef.isNotBlank()) { "authContextRef must not be blank." }
        return SLOT_PREFIX + authContextRef
    }

    private companion object {
        const val PREFERENCES_NAME = "com.independo.inderun.secure_storage"
        const val SLOT_PREFIX = "slot:"
    }
}
