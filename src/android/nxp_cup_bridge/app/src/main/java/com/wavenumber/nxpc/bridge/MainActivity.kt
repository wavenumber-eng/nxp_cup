package com.wavenumber.nxpc.bridge

import android.app.Activity
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.graphics.Bitmap
import android.graphics.Color
import android.graphics.Typeface
import android.hardware.usb.UsbDevice
import android.hardware.usb.UsbManager
import android.os.Build
import android.os.Bundle
import android.util.Log
import android.view.Gravity
import android.view.ViewGroup
import android.view.WindowManager
import android.widget.FrameLayout
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.TextView
import androidx.core.content.ContextCompat
import com.wavenumber.nxpc.bridge.protocol.NxpCupSystemActionRequestStatus
import com.wavenumber.nxpc.bridge.relay.NxpCupRelayServer
import com.wavenumber.nxpc.bridge.relay.NxpCupRelayVideoMode
import com.wavenumber.nxpc.bridge.usb.NxpCupUsbHealth
import com.wavenumber.nxpc.bridge.usb.NxpCupUsbSession
import com.wavenumber.nxpc.bridge.usb.NxpCupUsbState
import com.wavenumber.nxpc.bridge.video.NxpCupCodecInventory
import com.wavenumber.nxpc.bridge.video.NxpCupCompressionMode
import com.wavenumber.nxpc.bridge.video.NxpCupCompressionProbe
import com.wavenumber.nxpc.bridge.video.NxpCupFragmentedMp4Muxer
import java.nio.ByteBuffer
import java.util.Locale

class MainActivity : Activity() {
    companion object {
        private const val ACTION_USB_PERMISSION = "com.wavenumber.nxpc.bridge.USB_PERMISSION"
        private const val HEALTH_TAG = "NXP_CUP_BRIDGE_HEALTH"
        private const val COMPRESSION_TAG = "NXPC_COMPRESSION"
    }

    private lateinit var usbManager: UsbManager
    private lateinit var session: NxpCupUsbSession
    private lateinit var relayServer: NxpCupRelayServer
    private lateinit var statusView: TextView
    private lateinit var disconnectedView: TextView
    private lateinit var previewView: ImageView
    @Volatile
    private var compressionProbe: NxpCupCompressionProbe? = null
    private val previewBitmap = Bitmap.createBitmap(320, 200, Bitmap.Config.RGB_565)
    private var permissionPending = false
    private var lastHealth = NxpCupUsbHealth(NxpCupUsbState.IDLE, "waiting for NXP Cup USB device")
    private var relayVideoMode = NxpCupRelayVideoMode.JPEG
    private var jpegQuality = 70
    private var h264Bitrate = 750_000

    private val renderLoop = object : Runnable {
        override fun run() {
            val frame = if (::session.isInitialized) session.takeLatestFrame() else null
            if (frame != null) {
                try {
                    previewBitmap.copyPixelsFromBuffer(ByteBuffer.wrap(frame.pixels))
                    previewView.invalidate()
                } finally {
                    session.releaseFrame(frame)
                }
            }
            if (::previewView.isInitialized) previewView.postDelayed(this, 33)
        }
    }

    private val usbReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            when (intent?.action) {
                ACTION_USB_PERMISSION -> {
                    permissionPending = false
                    val device = intent.usbDevice()
                    if (intent.getBooleanExtra(UsbManager.EXTRA_PERMISSION_GRANTED, false) && device != null) {
                        session.start(device)
                    } else {
                        showHealth(NxpCupUsbHealth(NxpCupUsbState.ERROR, "USB permission denied"))
                    }
                }
                UsbManager.ACTION_USB_DEVICE_ATTACHED -> connectIfAvailable()
                UsbManager.ACTION_USB_DEVICE_DETACHED -> {
                    session.stop()
                    showHealth(NxpCupUsbHealth(NxpCupUsbState.DISCONNECTED, "NXP Cup USB device detached"))
                }
            }
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        ContextCompat.startForegroundService(
            this,
            Intent(this, BridgeKeepAliveService::class.java),
        )

        usbManager = getSystemService(Context.USB_SERVICE) as UsbManager
        val relayViewer = resources.openRawResource(R.raw.relay_viewer).use { it.readBytes() }
        val compressionOverride = NxpCupCompressionMode.parse(intent.getStringExtra("compression_probe"))
        relayVideoMode = compressionOverride?.let {
            when (it) {
                NxpCupCompressionMode.JPEG -> NxpCupRelayVideoMode.JPEG
                NxpCupCompressionMode.H264 -> NxpCupRelayVideoMode.H264
            }
        } ?: NxpCupRelayVideoMode.parse(intent.getStringExtra("relay_video")) ?: NxpCupRelayVideoMode.JPEG
        jpegQuality = intent.getIntExtra("jpeg_quality", 70)
        h264Bitrate = intent.getIntExtra("h264_bitrate", 750_000)
        relayServer = NxpCupRelayServer(
            relayViewer,
            port = intent.getIntExtra("relay_port", 8765),
            defaultVideoMode = relayVideoMode,
            onVideoModeChanged = ::selectRelayVideoMode,
            onSystemActionRequested = { action ->
                if (::session.isInitialized) {
                    session.requestSystemAction(action)
                } else {
                    NxpCupSystemActionRequestStatus.UNAVAILABLE
                }
            },
        )
        selectRelayVideoMode(relayVideoMode)
        relayServer.start()
        val avcEncoders = NxpCupCodecInventory.encoders()
        if (avcEncoders.isEmpty()) {
            Log.w("NXPC_CODEC_INVENTORY", "No AVC encoders reported")
        } else {
            avcEncoders.forEach { Log.i("NXPC_CODEC_INVENTORY", NxpCupCodecInventory.logLine(it)) }
        }
        session = NxpCupUsbSession(
            usbManager = usbManager,
            onHealth = ::showHealth,
            onCompletedFrame = { frame ->
                relayServer.noteSourceFrame(frame.frameId)
                relayServer.offerRawFrame(frame)
                compressionProbe?.offerFrame(frame)
            },
            onDiagnosticPacket = relayServer::offerDiagnostic,
            onSystemActionResult = relayServer::offerSystemActionResult,
        )
        previewView = ImageView(this).apply {
            setImageBitmap(previewBitmap)
            scaleType = ImageView.ScaleType.FIT_CENTER
            setBackgroundColor(Color.BLACK)
            contentDescription = "Live NXP Cup camera preview"
        }
        disconnectedView = TextView(this).apply {
            text = "CAR NOT CONNECTED"
            textSize = 30f
            gravity = Gravity.CENTER
            setTextColor(Color.WHITE)
            setBackgroundColor(Color.argb(180, 0, 0, 0))
            typeface = Typeface.DEFAULT_BOLD
        }
        val previewContainer = FrameLayout(this).apply {
            setBackgroundColor(Color.BLACK)
            addView(
                previewView,
                FrameLayout.LayoutParams(
                    ViewGroup.LayoutParams.MATCH_PARENT,
                    ViewGroup.LayoutParams.MATCH_PARENT,
                ),
            )
            addView(
                disconnectedView,
                FrameLayout.LayoutParams(
                    ViewGroup.LayoutParams.MATCH_PARENT,
                    ViewGroup.LayoutParams.MATCH_PARENT,
                ),
            )
        }
        statusView = TextView(this).apply {
            textSize = 16f
            gravity = Gravity.CENTER_VERTICAL
            setPadding(24, 10, 24, 12)
            setTextIsSelectable(true)
            setTextColor(Color.WHITE)
            setBackgroundColor(Color.rgb(24, 24, 24))
            maxLines = 2
        }
        val root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setBackgroundColor(Color.BLACK)
            addView(
                previewContainer,
                LinearLayout.LayoutParams(
                    ViewGroup.LayoutParams.MATCH_PARENT,
                    0,
                    1f,
                ),
            )
            addView(
                statusView,
                LinearLayout.LayoutParams(
                    ViewGroup.LayoutParams.MATCH_PARENT,
                    ViewGroup.LayoutParams.WRAP_CONTENT,
                ),
            )
        }
        setContentView(root)
        updatePhoneDisplay(lastHealth)
        previewView.post(renderLoop)

        val filter = IntentFilter().apply {
            addAction(ACTION_USB_PERMISSION)
            addAction(UsbManager.ACTION_USB_DEVICE_ATTACHED)
            addAction(UsbManager.ACTION_USB_DEVICE_DETACHED)
        }
        ContextCompat.registerReceiver(
            this,
            usbReceiver,
            filter,
            ContextCompat.RECEIVER_NOT_EXPORTED,
        )
        connectIfAvailable()
    }

    override fun onResume() {
        super.onResume()
        if (::session.isInitialized) connectIfAvailable()
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        if (intent.action == UsbManager.ACTION_USB_DEVICE_ATTACHED && ::session.isInitialized) {
            connectIfAvailable()
        }
    }

    override fun onDestroy() {
        previewView.removeCallbacks(renderLoop)
        session.stop()
        relayServer.stop()
        compressionProbe?.close()
        stopService(Intent(this, BridgeKeepAliveService::class.java))
        unregisterReceiver(usbReceiver)
        super.onDestroy()
    }

    private fun connectIfAvailable() {
        val device = usbManager.deviceList.values.firstOrNull {
            it.vendorId == NxpCupUsbSession.NXPC_VENDOR_ID && it.productId == NxpCupUsbSession.NXPC_PRODUCT_ID
        }
        if (device == null) {
            showHealth(NxpCupUsbHealth(NxpCupUsbState.IDLE, "waiting for NXP Cup USB device"))
            return
        }
        if (usbManager.hasPermission(device)) {
            session.start(device)
            return
        }
        if (permissionPending) return
        permissionPending = true
        showHealth(NxpCupUsbHealth(NxpCupUsbState.IDLE, "USB permission required"))
        val permissionIntent = PendingIntent.getBroadcast(
            this,
            0,
            Intent(ACTION_USB_PERMISSION).setPackage(packageName),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_MUTABLE,
        )
        usbManager.requestPermission(device, permissionIntent)
    }

    private fun showHealth(health: NxpCupUsbHealth) {
        lastHealth = health
        relayServer.updateUsbHealth(health)
        runOnUiThread {
            val devices = usbManager.deviceList.values.toList()
            updatePhoneDisplay(health)
            Log.i(
                HEALTH_TAG,
                "state=${health.state.wireName} usb_devices=${devices.size} packets=${health.packets} " +
                    "bytes=${health.bytes} frames=${health.frames} fps=%.2f mib_s=%.3f ".format(
                        Locale.US,
                        health.framesPerSecond,
                        health.mebibytesPerSecond,
                    ) +
                    "seq_errors=${health.sequenceErrors} malformed=${health.malformedChunks} " +
                    "preview_drops=${health.previewDrops} session_id=${health.sessionId} " +
                    "detail=${health.detail.replace(' ', '_')}",
            )
        }
    }

    @Synchronized
    private fun selectRelayVideoMode(mode: NxpCupRelayVideoMode) {
        val currentProbe = compressionProbe
        val alreadyConfigured = relayVideoMode == mode &&
            ((mode == NxpCupRelayVideoMode.RAW && currentProbe == null) ||
                (mode != NxpCupRelayVideoMode.RAW && currentProbe != null))
        if (alreadyConfigured) return

        compressionProbe = null
        currentProbe?.close()
        relayVideoMode = mode
        val compressionMode = when (mode) {
            NxpCupRelayVideoMode.RAW -> null
            NxpCupRelayVideoMode.JPEG -> NxpCupCompressionMode.JPEG
            NxpCupRelayVideoMode.H264 -> NxpCupCompressionMode.H264
        }
        val h264Muxer = if (mode == NxpCupRelayVideoMode.H264) NxpCupFragmentedMp4Muxer() else null
        compressionProbe = compressionMode?.let { selectedMode ->
            NxpCupCompressionProbe(
                mode = selectedMode,
                jpegQuality = jpegQuality,
                h264Bitrate = h264Bitrate,
                onJpegFrame = if (selectedMode == NxpCupCompressionMode.JPEG) relayServer::offerJpegFrame else null,
                onH264Format = h264Muxer?.let { muxer ->
                    { format -> relayServer.offerH264Initialization(muxer.initialization(format)) }
                },
                onH264AccessUnit = h264Muxer?.let { muxer ->
                    { accessUnit -> relayServer.offerH264Fragment(muxer.fragment(accessUnit)) }
                },
            ) { snapshot ->
                Log.i(COMPRESSION_TAG, snapshot.logLine())
            }
        }
        if (::statusView.isInitialized) runOnUiThread { updatePhoneDisplay(lastHealth) }
    }

    private fun updatePhoneDisplay(health: NxpCupUsbHealth) {
        val connected = health.state == NxpCupUsbState.STREAMING
        disconnectedView.visibility = if (connected) android.view.View.GONE else android.view.View.VISIBLE
        disconnectedView.text = when (health.state) {
            NxpCupUsbState.OPENING, NxpCupUsbState.HELLO, NxpCupUsbState.CHANNELS, NxpCupUsbState.PING -> "CONNECTING TO CAR..."
            NxpCupUsbState.ERROR -> "CAR CONNECTION ERROR"
            else -> "CAR NOT CONNECTED"
        }
        val stateLabel = if (connected) "CONNECTED" else "DISCONNECTED"
        statusView.text = "$stateLabel  •  ${relayVideoMode.wireName.uppercase(Locale.US)}\n${relayServer.localUrl()}"
    }

    @Suppress("DEPRECATION")
    private fun Intent.usbDevice(): UsbDevice? =
        if (Build.VERSION.SDK_INT >= 33) {
            getParcelableExtra(UsbManager.EXTRA_DEVICE, UsbDevice::class.java)
        } else {
            getParcelableExtra(UsbManager.EXTRA_DEVICE)
        }
}
