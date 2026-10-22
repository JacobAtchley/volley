package app.volley.android.session

import android.content.Context
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import java.util.UUID

data class Pairing(val macId: String, val macName: String, val token: String)

/**
 * Persists this phone's identity and its paired Mac.
 * TODO: move the token to an Android Keystore-backed store.
 */
class PairingStore(context: Context) {

    private val prefs = context.getSharedPreferences("volley.pairing", Context.MODE_PRIVATE)

    val deviceId: String = prefs.getString(KEY_DEVICE_ID, null)
        ?: UUID.randomUUID().toString().also { prefs.edit().putString(KEY_DEVICE_ID, it).apply() }

    private val _pairing = MutableStateFlow(load())
    val pairing: StateFlow<Pairing?> = _pairing.asStateFlow()

    fun save(p: Pairing) {
        prefs.edit()
            .putString(KEY_MAC_ID, p.macId)
            .putString(KEY_MAC_NAME, p.macName)
            .putString(KEY_TOKEN, p.token)
            .apply()
        _pairing.value = p
    }

    fun clear() {
        prefs.edit().remove(KEY_MAC_ID).remove(KEY_MAC_NAME).remove(KEY_TOKEN).apply()
        _pairing.value = null
    }

    private fun load(): Pairing? {
        val id = prefs.getString(KEY_MAC_ID, null) ?: return null
        val token = prefs.getString(KEY_TOKEN, null) ?: return null
        return Pairing(id, prefs.getString(KEY_MAC_NAME, null) ?: "Mac", token)
    }

    private companion object {
        const val KEY_DEVICE_ID = "deviceId"
        const val KEY_MAC_ID = "macId"
        const val KEY_MAC_NAME = "macName"
        const val KEY_TOKEN = "token"
    }
}
