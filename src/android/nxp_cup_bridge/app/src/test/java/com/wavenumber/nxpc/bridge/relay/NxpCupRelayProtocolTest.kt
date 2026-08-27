package com.wavenumber.nxpc.bridge.relay

import com.wavenumber.nxpc.bridge.protocol.NxpCupSystemAction
import com.wavenumber.nxpc.bridge.protocol.NxpCupSystemActionOutcome
import com.wavenumber.nxpc.bridge.protocol.NxpCupSystemActionResult
import com.wavenumber.nxpc.bridge.video.NxpCupJpegFrameView
import com.wavenumber.nxpc.bridge.video.NxpCupVideoFrame
import java.nio.ByteBuffer
import java.nio.ByteOrder
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class NxpCupRelayProtocolTest {
    @Test
    fun relayAcceptsOnlyTheTwoTypedSystemActionCommands() {
        assertEquals(
            NxpCupSystemAction.RACE_START,
            NxpCupRelayProtocol.decodeSystemActionCommand(
                "{\"type\":\"system_action\",\"action\":\"race_start\"}".toByteArray(),
            ),
        )
        assertEquals(
            NxpCupSystemAction.STOP,
            NxpCupRelayProtocol.decodeSystemActionCommand(
                "{\"type\":\"system_action\",\"action\":\"stop\"}".toByteArray(),
            ),
        )
        assertEquals(
            null,
            NxpCupRelayProtocol.decodeSystemActionCommand(
                "{\"type\":\"system_action\",\"action\":\"start_motors\"}".toByteArray(),
            ),
        )
    }

    @Test
    fun systemActionResultIsBoundedJsonText() {
        val encoded = NxpCupRelayProtocol.encodeSystemActionResult(
            NxpCupSystemActionResult(
                NxpCupSystemAction.STOP,
                NxpCupSystemActionOutcome.FAILED,
                "bad \"status\"\nretry",
            ),
        ).toString(Charsets.UTF_8)

        assertEquals(
            "{\"type\":\"system_action_result\",\"action\":\"stop\",\"outcome\":\"failed\"," +
                "\"detail\":\"bad \\\"status\\\"\\nretry\"}",
            encoded,
        )
    }

    @Test
    fun relayModesParseClientWireNames() {
        assertEquals(NxpCupRelayVideoMode.RAW, NxpCupRelayVideoMode.parse("raw"))
        assertEquals(NxpCupRelayVideoMode.JPEG, NxpCupRelayVideoMode.parse("JPEG"))
        assertEquals(NxpCupRelayVideoMode.H264, NxpCupRelayVideoMode.parse("h264"))
        assertEquals(null, NxpCupRelayVideoMode.parse("png"))
    }

    @Test
    fun jpegFrameIsEncodedAsOneBoundedWebSocketPayload() {
        val jpeg = byteArrayOf(0xFF.toByte(), 0xD8.toByte(), 1, 2, 0xFF.toByte(), 0xD9.toByte())
        val packet = NxpCupRelayProtocol.encodeJpegFrame(
            NxpCupRelayFrame(
                frameId = 55,
                width = 320,
                height = 200,
                capturedNs = 123_456_789,
                bytes = jpeg,
                byteCount = jpeg.size,
                droppedBefore = true,
            ),
        )
        val view = ByteBuffer.wrap(packet).order(ByteOrder.LITTLE_ENDIAN)
        assertEquals(NxpCupRelayProtocol.JPEG_MAGIC, view.getInt(0))
        assertEquals(NxpCupRelayProtocol.JPEG_VERSION, view.get(4).toInt())
        assertEquals(NxpCupRelayProtocol.JPEG_HEADER_BYTES, view.get(5).toInt())
        assertEquals(NxpCupRelayProtocol.JPEG_FLAG_DROPPED_BEFORE, view.getShort(6).toInt())
        assertEquals(55, view.getInt(8))
        assertEquals(320, view.getShort(12).toInt())
        assertEquals(200, view.getShort(14).toInt())
        assertEquals(jpeg.size, view.getInt(16))
        assertEquals(123_456_789, view.getLong(20))
        assertArrayEquals(jpeg, packet.copyOfRange(NxpCupRelayProtocol.JPEG_HEADER_BYTES, packet.size))
    }

    @Test
    fun relayMailboxKeepsOnlyNewestEncodedFrame() {
        val mailbox = NxpCupRelayMailbox(maxFrameBytes = 8)
        for (frameId in 0L..4L) {
            mailbox.noteSourceFrame(frameId)
            mailbox.offerJpegFrame(
                NxpCupJpegFrameView(frameId, 1, 1, frameId, byteArrayOf(frameId.toByte()), 1),
            )
        }

        val latest = requireNotNull(mailbox.takeLatestFrame())
        assertEquals(4, latest.frameId)
        assertArrayEquals(byteArrayOf(4), latest.bytes.copyOf(latest.byteCount))
        assertTrue(latest.droppedBefore)
        val snapshot = mailbox.snapshot()
        assertEquals(5, snapshot.sourceFrames)
        assertEquals(5, snapshot.selectedFrames)
        assertEquals(4, snapshot.droppedFrames)
        mailbox.releaseSentFrame(latest, sent = true)
        assertEquals(1, mailbox.snapshot().sentFrames)
        assertEquals(1, mailbox.snapshot().sentBytes)
    }

    @Test
    fun failedSendMarksTheNextSelectedFrameAsFollowingADrop() {
        val mailbox = NxpCupRelayMailbox(maxFrameBytes = 8)
        mailbox.noteSourceFrame(1)
        mailbox.offerJpegFrame(NxpCupJpegFrameView(1, 1, 1, 1, byteArrayOf(1), 1))
        val failed = requireNotNull(mailbox.takeLatestFrame())
        mailbox.releaseSentFrame(failed, sent = false)
        mailbox.noteSourceFrame(2)
        mailbox.offerJpegFrame(NxpCupJpegFrameView(2, 1, 1, 2, byteArrayOf(2), 1))

        assertTrue(requireNotNull(mailbox.takeLatestFrame()).droppedBefore)
    }

    @Test
    fun h264InitializationCarriesCodecAndFragmentedMp4() {
        val mp4 = byteArrayOf(0, 0, 0, 8, 'f'.code.toByte(), 't'.code.toByte(), 'y'.code.toByte(), 'p'.code.toByte())
        val encoded = NxpCupRelayProtocol.encodeH264Packet(
            NxpCupH264RelayPacket(8, 123, true, true, true, 0x42000d, mp4),
        )
        val view = ByteBuffer.wrap(encoded).order(ByteOrder.LITTLE_ENDIAN)
        assertEquals(NxpCupRelayProtocol.H264_MAGIC, view.getInt(0))
        assertEquals(
            NxpCupRelayProtocol.H264_FLAG_INITIALIZATION or
                NxpCupRelayProtocol.H264_FLAG_KEY_FRAME or
                NxpCupRelayProtocol.H264_FLAG_DISCONTINUITY,
            view.getShort(6).toInt(),
        )
        assertEquals(0x42000d, view.getInt(28))
        assertArrayEquals(mp4, encoded.copyOfRange(NxpCupRelayProtocol.H264_HEADER_BYTES, encoded.size))
    }

    @Test
    fun rawRgb565FrameIsCopiedAndEncodedAsOnePayload() {
        val mailbox = NxpCupRelayMailbox(maxFrameBytes = 8)
        val source = byteArrayOf(0x00, 0xF8.toByte(), 0xE0.toByte(), 0x07)
        mailbox.noteSourceFrame(9)
        mailbox.offerRawFrame(NxpCupVideoFrame(9, 2, 1, source))
        source.fill(0)

        val frame = requireNotNull(mailbox.takeLatestFrame())
        val packet = NxpCupRelayProtocol.encodeRawFrame(frame)
        val view = ByteBuffer.wrap(packet).order(ByteOrder.LITTLE_ENDIAN)
        assertEquals(NxpCupRelayProtocol.RAW_MAGIC, view.getInt(0))
        assertEquals(NxpCupRelayProtocol.RAW_VERSION, view.get(4).toInt())
        assertEquals(NxpCupRelayProtocol.RAW_HEADER_BYTES, view.get(5).toInt())
        assertEquals(9, view.getInt(8))
        assertEquals(2, view.getShort(12).toInt())
        assertEquals(1, view.getShort(14).toInt())
        assertEquals(4, view.getInt(16))
        assertEquals(NxpCupRelayProtocol.RAW_PIXEL_FORMAT_RGB565_LE, view.getInt(28))
        assertArrayEquals(
            byteArrayOf(0x00, 0xF8.toByte(), 0xE0.toByte(), 0x07),
            packet.copyOfRange(NxpCupRelayProtocol.RAW_HEADER_BYTES, packet.size),
        )
        mailbox.releaseSentFrame(frame, sent = true)
    }
}
