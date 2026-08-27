package com.wavenumber.nxpc.bridge.relay

import com.wavenumber.nxpc.bridge.protocol.NxpCupPacket
import com.wavenumber.nxpc.bridge.protocol.NxpCupProtocol
import com.wavenumber.nxpc.bridge.protocol.NxpCupSystemAction
import com.wavenumber.nxpc.bridge.protocol.NxpCupSystemActionResult
import java.nio.ByteBuffer
import java.nio.ByteOrder

object NxpCupRelayProtocol {
    const val JPEG_MAGIC = 0x4A435641
    const val JPEG_VERSION = 1
    const val JPEG_HEADER_BYTES = 32
    const val JPEG_FLAG_DROPPED_BEFORE = 1
    const val H264_MAGIC = 0x34435641
    const val H264_VERSION = 1
    const val H264_HEADER_BYTES = 32
    const val H264_FLAG_INITIALIZATION = 1
    const val H264_FLAG_KEY_FRAME = 2
    const val H264_FLAG_DISCONTINUITY = 4
    const val RAW_MAGIC = 0x52435641
    const val RAW_VERSION = 1
    const val RAW_HEADER_BYTES = 32
    const val RAW_FLAG_DROPPED_BEFORE = 1
    const val RAW_PIXEL_FORMAT_RGB565_LE = 1
    private val raceStartCommand =
        "{\"type\":\"system_action\",\"action\":\"race_start\"}".toByteArray(Charsets.UTF_8)
    private val stopCommand =
        "{\"type\":\"system_action\",\"action\":\"stop\"}".toByteArray(Charsets.UTF_8)

    fun decodeSystemActionCommand(payload: ByteArray): NxpCupSystemAction? = when {
        payload.contentEquals(raceStartCommand) -> NxpCupSystemAction.RACE_START
        payload.contentEquals(stopCommand) -> NxpCupSystemAction.STOP
        else -> null
    }

    fun encodeSystemActionStatus(action: NxpCupSystemAction, outcome: String, detail: String): ByteArray =
        (
            "{\"type\":\"system_action_result\",\"action\":\"${action.wireName}\"," +
                "\"outcome\":\"${jsonEscape(outcome)}\",\"detail\":\"${jsonEscape(detail)}\"}"
            ).toByteArray(Charsets.UTF_8)

    fun encodeSystemActionResult(result: NxpCupSystemActionResult): ByteArray =
        encodeSystemActionStatus(result.action, result.outcome.wireName, result.detail)

    fun encodeJpegFrame(frame: NxpCupRelayFrame): ByteArray =
        ByteBuffer.allocate(JPEG_HEADER_BYTES + frame.byteCount)
            .order(ByteOrder.LITTLE_ENDIAN)
            .putInt(JPEG_MAGIC)
            .put(JPEG_VERSION.toByte())
            .put(JPEG_HEADER_BYTES.toByte())
            .putShort(if (frame.droppedBefore) JPEG_FLAG_DROPPED_BEFORE.toShort() else 0)
            .putInt(frame.frameId.toInt())
            .putShort(frame.width.toShort())
            .putShort(frame.height.toShort())
            .putInt(frame.byteCount)
            .putLong(frame.capturedNs)
            .putInt(0)
            .put(frame.bytes, 0, frame.byteCount)
            .array()

    fun encodeRawFrame(frame: NxpCupRelayFrame): ByteArray =
        ByteBuffer.allocate(RAW_HEADER_BYTES + frame.byteCount)
            .order(ByteOrder.LITTLE_ENDIAN)
            .putInt(RAW_MAGIC)
            .put(RAW_VERSION.toByte())
            .put(RAW_HEADER_BYTES.toByte())
            .putShort(if (frame.droppedBefore) RAW_FLAG_DROPPED_BEFORE.toShort() else 0)
            .putInt(frame.frameId.toInt())
            .putShort(frame.width.toShort())
            .putShort(frame.height.toShort())
            .putInt(frame.byteCount)
            .putLong(frame.capturedNs)
            .putInt(RAW_PIXEL_FORMAT_RGB565_LE)
            .put(frame.bytes, 0, frame.byteCount)
            .array()

    fun encodeH264Packet(packet: NxpCupH264RelayPacket): ByteArray {
        var flags = 0
        if (packet.initialization) flags = flags or H264_FLAG_INITIALIZATION
        if (packet.keyFrame) flags = flags or H264_FLAG_KEY_FRAME
        if (packet.discontinuity) flags = flags or H264_FLAG_DISCONTINUITY
        return ByteBuffer.allocate(H264_HEADER_BYTES + packet.bytes.size)
            .order(ByteOrder.LITTLE_ENDIAN)
            .putInt(H264_MAGIC)
            .put(H264_VERSION.toByte())
            .put(H264_HEADER_BYTES.toByte())
            .putShort(flags.toShort())
            .putInt(packet.frameId.toInt())
            .putShort(320.toShort())
            .putShort(200.toShort())
            .putInt(packet.bytes.size)
            .putLong(packet.capturedNs)
            .putInt(packet.codecConfig)
            .put(packet.bytes)
            .array()
    }

    fun encodeDiagnostic(packet: NxpCupPacket, sequence: Int): ByteArray = encodePacket(
        sequence = sequence,
        messageId = packet.header.messageId,
        flags = packet.header.flags and NxpCupProtocol.FLAG_DROPPED_BEFORE,
        arg0 = packet.header.arg0,
        arg1 = packet.header.arg1,
        arg2 = packet.header.arg2,
        payload = packet.payload,
    )

    private fun encodePacket(
        sequence: Int,
        messageId: Int,
        flags: Int,
        arg0: Int,
        arg1: Int,
        arg2: Int,
        payload: ByteArray,
    ): ByteArray = ByteBuffer.allocate(NxpCupProtocol.HEADER_BYTES + payload.size)
        .order(ByteOrder.LITTLE_ENDIAN)
        .putInt(NxpCupProtocol.MAGIC)
        .put(NxpCupProtocol.VERSION.toByte())
        .put(NxpCupProtocol.HEADER_BYTES.toByte())
        .putShort(flags.toShort())
        .putInt(messageId)
        .putInt(sequence)
        .putInt(payload.size)
        .putInt(arg0)
        .putInt(arg1)
        .putInt(arg2)
        .put(payload)
        .array()

    private fun jsonEscape(value: String): String = buildString(value.length) {
        value.forEach { character ->
            when (character) {
                '\\' -> append("\\\\")
                '"' -> append("\\\"")
                '\n' -> append("\\n")
                '\r' -> append("\\r")
                '\t' -> append("\\t")
                else -> if (character.code < 0x20) append('?') else append(character)
            }
        }
    }
}
