package com.example.file_share_app

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.net.wifi.ScanResult
import android.net.wifi.WifiManager
import android.net.wifi.p2p.WifiP2pConfig
import android.net.wifi.p2p.WifiP2pGroup
import android.net.wifi.p2p.WifiP2pInfo
import android.net.wifi.p2p.WifiP2pManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import java.net.Inet4Address
import java.net.NetworkInterface
import java.util.concurrent.atomic.AtomicBoolean

class MainActivity : FlutterActivity() {
    private val networkInfoChannelName = "swiftshare/network_info"
    private val p2pChannelName = "swiftshare/wifi_p2p"
    private val p2pEventsChannelName = "swiftshare/wifi_p2p_events"
    private val lifecycleChannelName = "swiftshare/transfer_lifecycle"

    private var wifiP2pManager: WifiP2pManager? = null
    private var p2pChannel: WifiP2pManager.Channel? = null
    private var p2pReceiver: BroadcastReceiver? = null
    private var peersSink: EventChannel.EventSink? = null
    private var currentPeers: List<Map<String, Any?>> = emptyList()
    private val mainHandler = Handler(Looper.getMainLooper())

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, networkInfoChannelName)
            .setMethodCallHandler { call, result ->
                if (call.method == "getActiveWifiInfo") {
                    result.success(readActiveNetworkInfo())
                } else {
                    result.notImplemented()
                }
            }

        setupWifiP2p(flutterEngine)
        setupTransferLifecycle(flutterEngine)
        registerP2pReceivers()
    }

    override fun onDestroy() {
        super.onDestroy()
        try {
            unregisterReceiver(p2pReceiver)
        } catch (_: Throwable) {}
        p2pReceiver = null
    }

    // ---------------------------------------------------------------------------
    // Wi-Fi Direct (swiftshare/wifi_p2p + swiftshare/wifi_p2p_events)
    // ---------------------------------------------------------------------------

    private fun setupWifiP2p(flutterEngine: FlutterEngine) {
        val manager = getSystemService(Context.WIFI_P2P_SERVICE) as? WifiP2pManager
        wifiP2pManager = manager
        if (manager != null) {
            p2pChannel = manager.initialize(this, mainLooper, null)
        }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, p2pChannelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "isSupportedAndEnabled" -> result.success(isP2pSupportedAndEnabled())
                    "getGroupInfo" -> requestGroupInfo(result)
                    "startDiscovery" -> result.success(startP2pDiscovery())
                    "stopDiscovery" -> {
                        stopP2pDiscovery()
                        result.success(null)
                    }
                    "connectTo" -> {
                        val address = call.argument<String>("deviceAddress")
                        if (address == null) {
                            result.error("bad_args", "deviceAddress is required", null)
                        } else {
                            result.success(connectP2p(address))
                        }
                    }
                    "disconnectGroup" -> {
                        removeP2pGroup()
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }

        EventChannel(flutterEngine.dartExecutor.binaryMessenger, p2pEventsChannelName)
            .setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    peersSink = events
                    if (currentPeers.isNotEmpty()) events?.success(currentPeers)
                }

                override fun onCancel(arguments: Any?) {
                    peersSink = null
                }
            })
    }

    private fun isP2pSupportedAndEnabled(): Boolean {
        if (wifiP2pManager == null || p2pChannel == null) return false
        val hasFeature =
            try {
                packageManager.hasSystemFeature(PackageManager.FEATURE_WIFI_DIRECT)
            } catch (_: Throwable) {
                false
            }
        if (!hasFeature) return false
        val wifi = applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
        return try {
            wifi.isWifiEnabled
        } catch (_: Throwable) {
            false
        }
    }

    // ---------------------------------------------------------------------------
    // Foreground service (swiftshare/transfer_lifecycle)
    // ---------------------------------------------------------------------------

    private fun setupTransferLifecycle(flutterEngine: FlutterEngine) {
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, lifecycleChannelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "startTransfer" -> {
                        startTransferForeground()
                        result.success(null)
                    }
                    "stopTransfer" -> {
                        stopTransferForeground()
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
    }

    private fun startTransferForeground() {
        val intent = Intent(this, TransferForegroundService::class.java)
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                startForegroundService(intent)
            } else {
                startService(intent)
            }
        } catch (_: Throwable) {}
    }

    private fun stopTransferForeground() {
        try {
            stopService(Intent(this, TransferForegroundService::class.java))
        } catch (_: Throwable) {}
    }

    private fun startP2pDiscovery(): Boolean {
        val manager = wifiP2pManager ?: return false
        val channel = p2pChannel ?: return false
        try {
            manager.discoverPeers(channel, silentActionListener())
            return true
        } catch (_: Throwable) {
            return false
        }
    }

    private fun stopP2pDiscovery() {
        val manager = wifiP2pManager ?: return
        val channel = p2pChannel ?: return
        try {
            manager.stopPeerDiscovery(channel, silentActionListener())
        } catch (_: Throwable) {}
    }

    private fun connectP2p(deviceAddress: String): Boolean {
        val manager = wifiP2pManager ?: return false
        val channel = p2pChannel ?: return false
        try {
            val config = WifiP2pConfig().apply { this.deviceAddress = deviceAddress }
            manager.connect(channel, config, silentActionListener())
            return true
        } catch (_: Throwable) {
            return false
        }
    }

    private fun removeP2pGroup() {
        val manager = wifiP2pManager ?: return
        val channel = p2pChannel ?: return
        try {
            manager.removeGroup(channel, silentActionListener())
        } catch (_: Throwable) {}
    }

    /**
     * Resolves the current P2P group state and completes [result] exactly once.
     * Async framework callbacks can stall (device switching radios / mid-teardown),
     * so a 4 s watchdog responds first if no callback fires.
     */
    private fun requestGroupInfo(result: MethodChannel.Result) {
        if (wifiP2pManager == null || p2pChannel == null) {
            result.success(emptyMap<String, Any?>())
            return
        }
        val completed = AtomicBoolean(false)
        fun respond(group: Map<String, Any?>) {
            if (completed.compareAndSet(false, true)) result.success(group)
        }
        mainHandler.postDelayed({ respond(emptyMap()) }, 4000)

        val manager = wifiP2pManager!!
        val channel = p2pChannel!!
        try {
            manager.requestConnectionInfo(channel) { info: WifiP2pInfo? ->
                val group = mutableMapOf<String, Any?>()
                group["inGroup"] = info != null && info.groupFormed
                group["isGroupOwner"] = info?.isGroupOwner == true
                info?.groupOwnerAddress?.hostAddress?.let { group["groupOwnerAddress"] = it }
                group["ownerIp"] = resolveP2pOwnerIp(info)
                try {
                    manager.requestGroupInfo(channel) { p2pGroup: WifiP2pGroup? ->
                        fillGroupDetails(p2pGroup, group)
                        respond(group)
                    }
                } catch (_: Throwable) {
                    respond(group)
                }
            }
        } catch (_: Throwable) {
            respond(emptyMap())
        }
    }

    private fun fillGroupDetails(p2pGroup: WifiP2pGroup?, group: MutableMap<String, Any?>) {
        try {
            group["networkName"] = p2pGroup?.networkName
            group["passphrase"] = p2pGroup?.passphrase
            val clients = p2pGroup?.clientList?.filterNotNull()?.map { it.deviceAddress }
            if (!clients.isNullOrEmpty()) group["clientIps"] = clients
        } catch (_: Throwable) {}
    }

    /** Group owner's P2P IP, preferring the framework's report then the p2p0 interface. */
    private fun resolveP2pOwnerIp(info: WifiP2pInfo?): String? {
        wrapTry { info?.groupOwnerAddress?.hostAddress?.takeIf { it.isNotEmpty() } }?.let { return it }
        return wrapTry { p2pInterfaceIpv4() }
    }

    private fun p2pInterfaceIpv4(): String? {
        val interfaces = NetworkInterface.getNetworkInterfaces() ?: return null
        while (interfaces.hasMoreElements()) {
            val networkInterface = interfaces.nextElement()
            val name = networkInterface.name
            if (name == null || !name.startsWith("p2p")) continue
            for (address in networkInterface.inetAddresses) {
                if (!address.isLoopbackAddress && address is Inet4Address) {
                    return address.hostAddress
                }
            }
        }
        return null
    }

    private fun registerP2pReceivers() {
        val manager = wifiP2pManager ?: return
        val receiver = object : BroadcastReceiver() {
            override fun onReceive(context: Context, intent: Intent) {
                when (intent.action) {
                    WifiP2pManager.WIFI_P2P_STATE_CHANGED_ACTION -> {
                        val state = intent.getIntExtra(WifiP2pManager.EXTRA_WIFI_STATE, -1)
                        if (state != WifiP2pManager.WIFI_P2P_STATE_ENABLED) {
                            currentPeers = mutableListOf()
                            peersSink?.success(currentPeers)
                        }
                    }
                    WifiP2pManager.WIFI_P2P_PEERS_CHANGED_ACTION -> {
                        try {
                            manager.requestPeers(p2pChannel) { peerList ->
                                val peers = peerList.deviceList.map { peer ->
                                    mapOf<String, Any?>(
                                        "deviceAddress" to peer.deviceAddress,
                                        "deviceName" to peer.deviceName,
                                        "isGroupOwner" to peer.isGroupOwner,
                                    )
                                }
                                currentPeers = peers
                                peersSink?.success(peers)
                            }
                        } catch (_: Throwable) {}
                    }
                    WifiP2pManager.WIFI_P2P_CONNECTION_CHANGED_ACTION -> {
                        // Group state changed; the Dart side re-queries getGroupInfo.
                    }
                    else -> {}
                }
            }
        }
        p2pReceiver = receiver
        try {
            registerReceiver(receiver, p2pIntentFilter())
        } catch (_: Throwable) {}
    }

    private fun p2pIntentFilter(): IntentFilter =
        IntentFilter().apply {
            addAction(WifiP2pManager.WIFI_P2P_STATE_CHANGED_ACTION)
            addAction(WifiP2pManager.WIFI_P2P_PEERS_CHANGED_ACTION)
            addAction(WifiP2pManager.WIFI_P2P_CONNECTION_CHANGED_ACTION)
            addAction(WifiP2pManager.WIFI_P2P_THIS_DEVICE_CHANGED_ACTION)
        }

    private fun silentActionListener() = object : WifiP2pManager.ActionListener {
        override fun onSuccess() {}
        override fun onFailure(reason: Int) {}
    }

    private fun <T> wrapTry(block: () -> T): T? = try {
        block()
    } catch (_: Throwable) {
        null
    }

    // ---------------------------------------------------------------------------
    // Network info (swiftshare/network_info)
    // ---------------------------------------------------------------------------

    /**
     * Reads the active network's transport type and, when connected over Wi-Fi,
     * the negotiated link parameters (frequency/band, link speeds, standard,
     * SSID/BSSID where permitted). Values unavailable on this SDK level or
     * without the required permissions are omitted rather than fabricated.
     */
    private fun readActiveNetworkInfo(): Map<String, Any?> {
        val out = mutableMapOf<String, Any?>()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            try {
                val cm = getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
                val network = cm.activeNetwork
                val caps = network?.let { cm.getNetworkCapabilities(it) }
                out["transportType"] = when {
                    caps?.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) == true -> "wifi"
                    caps?.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET) == true -> "ethernet"
                    caps?.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR) == true -> "cellular"
                    else -> "unknown"
                }
                out["isMetered"] =
                    caps?.hasCapability(NetworkCapabilities.NET_CAPABILITY_NOT_METERED) == false
            } catch (_: Throwable) {
            }
        }

        try {
            val wifi = applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
            val info = wifi.connectionInfo
            out["ssid"] = try { info.ssid } catch (_: Throwable) { null }
            out["bssid"] = try { info.bssid } catch (_: Throwable) { null }
            out["linkSpeed"] = try { info.linkSpeed } catch (_: Throwable) { null }
            out["rssi"] = try { info.rssi } catch (_: Throwable) { null }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.LOLLIPOP) {
                val frequencyMhz = try { info.frequency } catch (_: Throwable) { -1 }
                out["frequency"] = frequencyMhz.let { if (it > 0) it else null }
                out["is5GHz"] = frequencyIn(frequencyMhz, 4900..5900)
                out["is6GHz"] = frequencyIn(frequencyMhz, 5925..7125)
            }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                out["wifiStandard"] = try {
                    when (info.wifiStandard) {
                        ScanResult.WIFI_STANDARD_11N -> "Wi-Fi 4"
                        ScanResult.WIFI_STANDARD_11AC -> "Wi-Fi 5"
                        ScanResult.WIFI_STANDARD_11AX -> "Wi-Fi 6"
                        ScanResult.WIFI_STANDARD_11AD -> "Wi-Fi AD"
                        ScanResult.WIFI_STANDARD_11BE -> "Wi-Fi 7"
                        else -> null
                    }
                } catch (_: Throwable) {
                    null
                }
                // Receive link speed (Rx Mbps) is only reported from API 31+.
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                    out["rxLinkSpeed"] = try { info.rxLinkSpeedMbps } catch (_: Throwable) { null }
                }
            }
        } catch (_: Throwable) {
            // Wi-Fi info requires ACCESS_WIFI_STATE + (for SSID) location;
            // any failure just leaves those fields out.
        }
        return out
    }

    /** 802.11 band check derived from the reported center frequency. */
    private fun frequencyIn(frequencyMhz: Int, range: IntRange): Boolean? {
        if (frequencyMhz <= 0) return null
        return frequencyMhz in range
    }
}