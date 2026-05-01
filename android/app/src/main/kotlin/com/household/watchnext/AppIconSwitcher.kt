package com.household.watchnext

import android.app.Activity
import android.content.ComponentName
import android.content.pm.PackageManager
import android.util.Log

/**
 * Toggles which `activity-alias` is enabled in the manifest so the user can
 * pick their launcher icon. Order is load-bearing: enable the new alias
 * BEFORE disabling the others, so there's never a moment when zero aliases
 * are enabled (Android would treat the app as launcher-removed and the home
 * screen shortcut would vanish).
 *
 * `DONT_KILL_APP` keeps the running process intact during the swap; without
 * it, a user picking from Settings would have their session terminated.
 *
 * Call from MainActivity via the `wn/app_icon` MethodChannel.
 */
class AppIconSwitcher(private val activity: Activity) {

    private val pkg: String = activity.packageName

    private val aliases = listOf(
        Alias(short = "Classic", className = "$pkg.LauncherClassic"),
        Alias(short = "Vivid", className = "$pkg.LauncherVivid"),
        Alias(short = "Minimal", className = "$pkg.LauncherMinimal"),
        Alias(short = "Clapper", className = "$pkg.LauncherClapper"),
        Alias(short = "Cream", className = "$pkg.LauncherCream"),
    )

    /** Returns the short name (e.g. "Classic") of whichever alias is currently enabled.
     *
     *  In manifest: only Classic has `enabled="true"`; the others ship as
     *  `enabled="false"`. The PackageManager reports `STATE_DEFAULT` for any
     *  alias the user hasn't explicitly toggled — for those we fall back to
     *  the manifest-declared default. */
    fun getCurrentAlias(): String {
        val pm = activity.packageManager
        for (alias in aliases) {
            val component = ComponentName(pkg, alias.className)
            val state = pm.getComponentEnabledSetting(component)
            when (state) {
                PackageManager.COMPONENT_ENABLED_STATE_ENABLED -> return alias.short
                PackageManager.COMPONENT_ENABLED_STATE_DEFAULT ->
                    if (alias.short == "Classic") return alias.short
                else -> { /* DISABLED — keep scanning */ }
            }
        }
        // Defensive fallback — should be unreachable given the invariant.
        return "Classic"
    }

    /** Enable the chosen alias and disable every other. */
    fun setAlias(target: String): Boolean {
        val match = aliases.firstOrNull { it.short.equals(target, ignoreCase = true) }
        if (match == null) {
            Log.w("WnAppIcon", "setAlias: unknown target=$target")
            return false
        }
        val pm = activity.packageManager
        // 1) Enable the new alias FIRST. If we disabled before enabling and the
        // app was killed mid-swap, the device would be left with zero enabled
        // aliases — i.e., no launcher icon.
        pm.setComponentEnabledSetting(
            ComponentName(pkg, match.className),
            PackageManager.COMPONENT_ENABLED_STATE_ENABLED,
            PackageManager.DONT_KILL_APP,
        )
        // 2) Now disable every other alias.
        for (alias in aliases) {
            if (alias.className == match.className) continue
            pm.setComponentEnabledSetting(
                ComponentName(pkg, alias.className),
                PackageManager.COMPONENT_ENABLED_STATE_DISABLED,
                PackageManager.DONT_KILL_APP,
            )
        }
        Log.d("WnAppIcon", "setAlias: enabled ${match.short}")
        return true
    }

    private data class Alias(val short: String, val className: String)
}
