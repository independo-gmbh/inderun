package com.independo.inderun.sdk

import android.content.Context
import com.independo.inderun.core.HostServices
import com.independo.inderun.core.HostServicesFactory

/**
 * The primary entry point for the IndeRun Android SDK.
 * 
 * This class provides access to all platform-specific [HostServices] required
 * by the IndeRun engine, such as connectivity, secure storage, and time.
 */
class IndeRun private constructor(private val hostServices: HostServices) {

    /** Accessor for connectivity information. */
    val connectivity = hostServices.connectivity
    
    /** Accessor for secure credential/secret storage. */
    val secureStorage = hostServices.secureStorage
    
    /** Accessor for the system clock. */
    val clock = hostServices.clock

    companion object {
        /**
         * Initializes the IndeRun SDK with a given Android [Context].
         *
         * @param context The application or activity context.
         * @return A new instance of the [IndeRun] SDK.
         */
        fun initialize(context: Context): IndeRun {
            val services = HostServicesFactory.create(context.applicationContext)
            return IndeRun(services)
        }
    }
}
