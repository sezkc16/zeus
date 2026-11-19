// Adapted from CloudStream (https://github.com/recloudstream/cloudstream), GPL-3.0.
package com.lagradost.cloudstream3.plugins

import android.content.Context
import android.content.res.Resources
import com.lagradost.cloudstream3.actions.VideoClickAction

/** Base class Android-flavoured plugins extend; mirrors the app's `plugins.Plugin`. */
abstract class Plugin : BasePlugin() {
    companion object {
        /**
         * Synthetic field the Jetpack Compose compiler plugin normally generates
         * on every class it processes (`public static final int $stable`).
         * Compose-built plugins (e.g. Phisher's Cinefreak/Comix) read
         * `Plugin.$stable` from their superclass static initializer; without
         * it they fail to load with NoSuchFieldError. The engine applies no
         * Compose plugin, so declare it manually. `@JvmField` exposes it as
         * a static field on `Plugin` itself (same pattern as Parcelable
         * `CREATOR`).
         *
         * Value 8, not 0: the field is a Compose stability bitmask (0 =
         * Stable, 8 = Unstable in the first stability slot). `Plugin` has
         * mutable properties (`resources`, `openSettings`), so 8 is the
         * honest value; 0 would falsely describe a mutable class as stable.
         * The JVM linker only cares that the field exists with the right
         * declaring class, name, type and access — not its value.
         */
        @JvmField
        val `$stable`: Int = 8
    }

    /** Called when the plugin is loaded. Falls back to the cross-platform [load]. */
    @Throws(Throwable::class)
    open fun load(context: Context) {
        load()
    }

    /** The app lists these on a video's links; SkyStream shows none, so the action is only marked as the plugin's. */
    fun registerVideoClickAction(element: VideoClickAction) {
        element.sourcePlugin = this.filename
    }

    /** Set when the plugin's manifest asks for resources (not supported off-Android yet). */
    var resources: Resources? = null

    /** Settings screen entry point; the host decides whether it can show it. */
    var openSettings: ((context: Context) -> Unit)? = null
}
