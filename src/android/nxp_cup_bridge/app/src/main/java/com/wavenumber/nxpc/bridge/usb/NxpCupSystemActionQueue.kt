package com.wavenumber.nxpc.bridge.usb

import com.wavenumber.nxpc.bridge.protocol.NxpCupSystemAction
import com.wavenumber.nxpc.bridge.protocol.NxpCupSystemActionRequestStatus

internal data class NxpCupSystemActionOffer(
    val status: NxpCupSystemActionRequestStatus,
    val superseded: NxpCupSystemAction? = null,
)

internal class NxpCupSystemActionQueue {
    private var pending: NxpCupSystemAction? = null

    @Synchronized
    fun offer(action: NxpCupSystemAction): NxpCupSystemActionOffer {
        val queued = pending
        return when {
            queued == null -> {
                pending = action
                NxpCupSystemActionOffer(NxpCupSystemActionRequestStatus.QUEUED)
            }
            action == NxpCupSystemAction.STOP && queued == NxpCupSystemAction.RACE_START -> {
                pending = action
                NxpCupSystemActionOffer(NxpCupSystemActionRequestStatus.QUEUED, superseded = queued)
            }
            else -> NxpCupSystemActionOffer(NxpCupSystemActionRequestStatus.BUSY)
        }
    }

    @Synchronized
    fun poll(): NxpCupSystemAction? = pending.also { pending = null }

    @Synchronized
    fun clear(): NxpCupSystemAction? = pending.also { pending = null }
}
