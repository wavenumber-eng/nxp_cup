package com.wavenumber.nxpc.bridge.usb

import com.wavenumber.nxpc.bridge.protocol.NxpCupSystemAction
import com.wavenumber.nxpc.bridge.protocol.NxpCupSystemActionRequestStatus
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class NxpCupSystemActionQueueTest {
    @Test
    fun queueIsBoundedToOnePendingAction() {
        val queue = NxpCupSystemActionQueue()

        assertEquals(
            NxpCupSystemActionRequestStatus.QUEUED,
            queue.offer(NxpCupSystemAction.RACE_START).status,
        )
        assertEquals(
            NxpCupSystemActionRequestStatus.BUSY,
            queue.offer(NxpCupSystemAction.RACE_START).status,
        )
        assertEquals(NxpCupSystemAction.RACE_START, queue.poll())
        assertNull(queue.poll())
    }

    @Test
    fun stopSupersedesAStartThatHasNotReachedUsb() {
        val queue = NxpCupSystemActionQueue()
        queue.offer(NxpCupSystemAction.RACE_START)

        val stop = queue.offer(NxpCupSystemAction.STOP)

        assertEquals(NxpCupSystemActionRequestStatus.QUEUED, stop.status)
        assertEquals(NxpCupSystemAction.RACE_START, stop.superseded)
        assertEquals(NxpCupSystemAction.STOP, queue.poll())
    }

    @Test
    fun clearReturnsThePendingActionForFailureReporting() {
        val queue = NxpCupSystemActionQueue()
        queue.offer(NxpCupSystemAction.STOP)

        assertEquals(NxpCupSystemAction.STOP, queue.clear())
        assertNull(queue.clear())
    }
}
