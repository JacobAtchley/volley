package app.volley.android.notifications

import android.content.Context

/** Apps the user excluded on the Mac. Pushed via `notification.filter`; kept across restarts. */
class ExcludedPackages(context: Context) {
    private val prefs = context.getSharedPreferences("volley_filter", Context.MODE_PRIVATE)

    @Volatile
    var current: Set<String> = prefs.getStringSet(KEY, emptySet())!!.toSet()
        private set

    fun set(pkgs: Set<String>) {
        current = pkgs
        prefs.edit().putStringSet(KEY, pkgs).apply()
    }

    private companion object {
        const val KEY = "excluded"
    }
}
