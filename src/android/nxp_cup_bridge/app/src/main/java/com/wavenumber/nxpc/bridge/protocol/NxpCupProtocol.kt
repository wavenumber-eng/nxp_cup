package com.wavenumber.nxpc.bridge.protocol

import java.nio.ByteBuffer
import java.nio.ByteOrder

object NxpCupProtocol {
    const val MAGIC: Int = 0x55435641
    const val VERSION: Int = 1
    const val HEADER_BYTES: Int = 32
    const val MAX_PAYLOAD_BYTES: Int = (16 * 1024) - HEADER_BYTES

    const val FRAME_CHUNK_HEADER_BYTES: Int = 24
    const val LOG_RECORD_HEADER_BYTES: Int = 12
    const val TELEMETRY_SCALAR_HEADER_BYTES: Int = 16
    const val TELEMETRY_TEXT_MAX_BYTES: Int = 48
    const val STATS_REPORT_BYTES: Int = 76
    const val HELLO_RESPONSE_BYTES: Int = 24

    const val MSG_RUI_WRITE_FRAME_BUFFER_RAW: Int = 0x01000002
    const val MSG_LOG_TEXT: Int = 0x01000200
    const val MSG_STATS_REPORT: Int = 0x01000300
    const val MSG_CONTROL_HELLO: Int = 0x01000403
    const val MSG_CONTROL_SET_CHANNELS: Int = 0x01000404
    const val MSG_CONTROL_PING: Int = 0x01000405
    const val MSG_CONTROL_CLOSE: Int = 0x01000406
    const val MSG_CONTROL_ERROR: Int = 0x01000407
    const val MSG_CONTROL_SYSTEM_ACTION: Int = 0x01000409
    const val MSG_TELEMETRY_SCALAR: Int = 0x01000500

    const val FLAG_RESPONSE: Int = 1 shl 0
    const val FLAG_MORE: Int = 1 shl 1
    const val FLAG_PAYLOAD_CRC32: Int = 1 shl 2
    const val FLAG_DROPPED_BEFORE: Int = 1 shl 3

    const val CHUNK_FRAME_START: Int = 1 shl 0
    const val CHUNK_FRAME_END: Int = 1 shl 1
    const val CHUNK_STALE_OK: Int = 1 shl 2

    const val PIXEL_FORMAT_RGB565_LE: Int = 1

    const val TELEMETRY_I32: Int = 1
    const val TELEMETRY_U32: Int = 2
    const val TELEMETRY_F32: Int = 3
    const val TELEMETRY_BOOL: Int = 4
    const val TELEMETRY_TEXT: Int = 5

    const val CHANNEL_FRAMES: Int = 1 shl 0
    const val CHANNEL_STATS: Int = 1 shl 1
    const val CHANNEL_LOGS: Int = 1 shl 2
    const val CHANNEL_TELEMETRY: Int = 1 shl 3

    const val CAPABILITY_SYSTEM_ACTIONS: Int = 1 shl 7
    const val SYSTEM_ACTION_RACE_START: Int = 1
    const val SYSTEM_ACTION_STOP: Int = 2
    const val RACE_START_CONFIRMATION: Int = 0x21214F47

    const val CONTROL_STATUS_OK: Int = 0
    const val CONTROL_STATUS_NOT_READY: Int = 6
    const val CONTROL_STATUS_DENIED: Int = 7
}

data class NxpCupPacketHeader(
    val flags: Int,
    val messageId: Int,
    val sequence: Int,
    val payloadLength: Int,
    val arg0: Int,
    val arg1: Int,
    val arg2: Int,
)

data class NxpCupPacket(
    val header: NxpCupPacketHeader,
    val payload: ByteArray,
)

object NxpCupControlPacketBuilder {
    fun build(
        sequence: Int,
        messageId: Int,
        arg0: Int = 0,
        arg1: Int = 0,
        arg2: Int = 0,
    ): ByteArray = ByteBuffer.allocate(NxpCupProtocol.HEADER_BYTES)
        .order(ByteOrder.LITTLE_ENDIAN)
        .putInt(NxpCupProtocol.MAGIC)
        .put(NxpCupProtocol.VERSION.toByte())
        .put(NxpCupProtocol.HEADER_BYTES.toByte())
        .putShort(0)
        .putInt(messageId)
        .putInt(sequence)
        .putInt(0)
        .putInt(arg0)
        .putInt(arg1)
        .putInt(arg2)
        .array()
}
