package com.independo.inderun.core

import android.content.Context
import androidx.test.core.app.ApplicationProvider
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner

@RunWith(RobolectricTestRunner::class)
class SecureStorageServiceTest {
    private lateinit var secureStorage: SecureStorageService

    @Before
    fun setUp() {
        val context = ApplicationProvider.getApplicationContext<Context>()
        context.getSharedPreferences(PREFERENCES_NAME, Context.MODE_PRIVATE)
            .edit()
            .clear()
            .commit()
        secureStorage = SecureStorageServiceImpl(context)
    }

    @Test
    fun putGetAndRemove_respectsCredentialSlots() {
        secureStorage.put("openai_primary", "secret-token")

        assertEquals("secret-token", secureStorage.get("openai_primary"))

        secureStorage.remove("openai_primary")

        assertNull(secureStorage.get("openai_primary"))
    }

    companion object {
        private const val PREFERENCES_NAME = "com.independo.inderun.secure_storage"
    }
}
