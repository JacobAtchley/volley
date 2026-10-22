package app.volley.android.status

import app.volley.android.protocol.DeviceStatus
import org.junit.Assert.assertEquals
import org.junit.Test

class StatusThrottleTest {
    private val throttle = StatusThrottle(minIntervalMs = 30_000)
    private val base = DeviceStatus(battery = 80, charging = false, cellLevel = 3, wifiLevel = 4, wifiConnected = true)

    @Test
    fun firstOfferSends() = assertEquals(Decision.Send, throttle.offer(base, 0))

    @Test
    fun identicalStatusSkips() {
        throttle.offer(base, 0)
        assertEquals(Decision.Skip, throttle.offer(base, 60_000))
    }

    @Test
    fun changeWithinIntervalDefers() {
        throttle.offer(base, 0)
        assertEquals(Decision.Defer(30_000), throttle.offer(base.copy(battery = 79), 10_000))
    }

    @Test
    fun chargingToggleBypassesInterval() {
        throttle.offer(base, 0)
        assertEquals(Decision.Send, throttle.offer(base.copy(charging = true), 1_000))
    }

    @Test
    fun changeAfterIntervalSends() {
        throttle.offer(base, 0)
        assertEquals(Decision.Send, throttle.offer(base.copy(battery = 79), 30_000))
        assertEquals(Decision.Skip, throttle.offer(base.copy(battery = 79), 31_000))
    }

    @Test
    fun resetMakesNextOfferSend() {
        throttle.offer(base, 0)
        throttle.reset()
        assertEquals(Decision.Send, throttle.offer(base, 1_000))
    }
}
