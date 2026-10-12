package org.persiantrend.platform;

import android.Manifest;
import android.app.Activity;
import android.app.Application;
import android.bluetooth.BluetoothAdapter;
import android.bluetooth.BluetoothManager;
import android.app.KeyguardManager;
import android.app.NotificationManager;
import android.app.NotificationChannel;
import android.content.Context;
import android.content.Intent;
import android.content.IntentFilter;
import android.content.pm.PackageManager;
import android.net.ConnectivityManager;
import android.net.Network;
import android.net.NetworkCapabilities;
import android.net.wifi.WifiManager;
import android.os.BatteryManager;
import android.os.Build;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.os.PowerManager;
import android.os.SystemClock;
import android.provider.Settings;
import java.io.OutputStream;
import java.net.InetAddress;
import java.net.NetworkInterface;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.Collections;
import java.util.HashMap;
import java.util.Map;
import java.util.HashSet;
import java.util.Set;
import io.flutter.embedding.engine.plugins.FlutterPlugin;
import io.flutter.embedding.engine.plugins.activity.ActivityAware;
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding;
import io.flutter.plugin.common.MethodCall;
import io.flutter.plugin.common.MethodChannel;
import io.flutter.plugin.common.PluginRegistry;

public final class PilotPlatformPlugin implements FlutterPlugin, ActivityAware,
    MethodChannel.MethodCallHandler, PluginRegistry.ActivityResultListener,
    PluginRegistry.RequestPermissionsResultListener {
  private Context context;
  private Activity activity;
  private ActivityPluginBinding activityBinding;
  private MethodChannel channel;
  private MethodChannel.Result exportResult, permissionResult;
  private MethodChannel.Result bluetoothEnableResult;
  private String report;
  private WifiManager.MulticastLock discoveryLock;
  private static final int EXPORT = 4811, NOTIFICATIONS = 4812, NEARBY = 4813, BLUETOOTH_ENABLE = 4814;
  private WiFiDirectTransport wifiDirect;
  private BleTransportBridge bluetooth;
  private LocalWifiTransport localWifi;
  private static final Set<PilotPlatformPlugin> INSTANCES = new HashSet<>();
  private static final Set<Activity> RESUMED = new HashSet<>();
  private static boolean lifecycleRegistered;
  private Object identityLeaseOwner;
  private static final Handler IDENTITY_HANDLER = new Handler(Looper.getMainLooper());
  private static final IdentityLeaseQueue IDENTITY_LEASES = new IdentityLeaseQueue(
      new IdentityLeaseQueue.Scheduler() {
        public void postDelayed(Runnable task, long delayMillis) { IDENTITY_HANDLER.postDelayed(task, delayMillis); }
        public void remove(Runnable task) { IDENTITY_HANDLER.removeCallbacks(task); }
      });

  @Override public void onAttachedToEngine(FlutterPluginBinding binding) {
    identityLeaseOwner = new Object();
    context = binding.getApplicationContext();
    channel = new MethodChannel(binding.getBinaryMessenger(), "persiantrend/device");
    channel.setMethodCallHandler(this);
    INSTANCES.add(this);
    if (!lifecycleRegistered && context instanceof Application) {
      lifecycleRegistered = true;
      ((Application) context).registerActivityLifecycleCallbacks(new Application.ActivityLifecycleCallbacks() {
        public void onActivityCreated(Activity a, Bundle b) {}
        public void onActivityStarted(Activity a) {}
        public void onActivityResumed(Activity a) { RESUMED.add(a); updateVisibility(); }
        public void onActivityPaused(Activity a) { RESUMED.remove(a); updateVisibility(); }
        public void onActivityStopped(Activity a) {}
        public void onActivitySaveInstanceState(Activity a, Bundle b) {}
        public void onActivityDestroyed(Activity a) { RESUMED.remove(a); updateVisibility(); }
      });
    }
    NotificationChannel receiving = new NotificationChannel("persiantrend_receiving", "Receiving test bulletins", NotificationManager.IMPORTANCE_LOW);
    receiving.setDescription("Visible while you choose to receive and share pilot bulletins");
    receiving.setShowBadge(false);
    ((NotificationManager)context.getSystemService(Context.NOTIFICATION_SERVICE)).createNotificationChannel(receiving);
  }
  @Override public void onDetachedFromEngine(FlutterPluginBinding binding) {
    Object detachedOwner = identityLeaseOwner;
    identityLeaseOwner = null;
    if (Looper.myLooper() == Looper.getMainLooper()) IDENTITY_LEASES.detach(detachedOwner);
    else IDENTITY_HANDLER.post(() -> IDENTITY_LEASES.detach(detachedOwner));
    stopNearby();
    if (localWifi != null) { localWifi.stop(); localWifi = null; }
    INSTANCES.remove(this);
    try { setDiscoveryActive(false); }
    catch (RuntimeException ignored) { /* Engine detach must still complete. */ }
    channel.setMethodCallHandler(null);
  }
  @Override public void onAttachedToActivity(ActivityPluginBinding binding) {
    activityBinding = binding;
    activity = binding.getActivity();
    binding.addActivityResultListener(this);
    binding.addRequestPermissionsResultListener(this);
  }
  @Override public void onDetachedFromActivity() {
    if (activityBinding != null) {
      activityBinding.removeActivityResultListener(this);
      activityBinding.removeRequestPermissionsResultListener(this);
    }
    activityBinding = null;
    activity = null;
    if (permissionResult != null) { permissionResult.success(null); permissionResult = null; }
    if (bluetoothEnableResult != null) { bluetoothEnableResult.success(null); bluetoothEnableResult = null; }
    if (exportResult != null) { exportResult.success(false); exportResult = null; report = null; }
  }
  @Override public void onDetachedFromActivityForConfigChanges() { onDetachedFromActivity(); }
  @Override public void onReattachedToActivityForConfigChanges(ActivityPluginBinding binding) { onAttachedToActivity(binding); }

  @Override public void onMethodCall(MethodCall call, MethodChannel.Result result) {
    if ((call.method.equals("acquireIdentityLease") || call.method.equals("releaseIdentityLease"))
        && Looper.myLooper() != Looper.getMainLooper()) {
      IDENTITY_HANDLER.post(() -> onMethodCall(call, result));
      return;
    }
    try {
      switch (call.method) {
        case "acquireIdentityLease":
          if (identityLeaseOwner == null) {
            result.error("identity_lease_detached", "Identity service is unavailable", null); return;
          }
          IDENTITY_LEASES.acquire(identityLeaseOwner, new IdentityLeaseQueue.Callback() {
            public void granted(String token) { result.success(token); }
            public void failed(String code) { result.error(code, "Identity initialization is busy or unavailable", null); }
          });
          return;
        case "releaseIdentityLease":
          Object token = call.argument("token");
          if (!(token instanceof String) || identityLeaseOwner == null
              || !IDENTITY_LEASES.release(identityLeaseOwner, (String) token)) {
            result.error("identity_lease_invalid", "Identity lease is no longer owned", null); return;
          }
          result.success(null); return;
        case "state": result.success(state()); return;
        case "startLocalWifi":
          Number localTcp = call.argument("tcpPort"), localIngress = call.argument("ingressPort"),
              directIngress = call.argument("wifiDirectIngressPort"), discoveryPort = call.argument("discoveryPort");
          byte[] localBeacon = call.argument("signedBeacon");
          if (localTcp == null || localIngress == null || directIngress == null || discoveryPort == null) {
            result.error("arguments", "Invalid local Wi-Fi configuration", null); return;
          }
          if (localWifi == null) localWifi = new LocalWifiTransport(context, this::emitTransport);
          localWifi.start(localTcp.intValue(), localIngress.intValue(), directIngress.intValue(),
              discoveryPort.intValue(), localBeacon);
          if (wifiDirect != null) wifiDirect.setAutoConnectAllowed(false);
          if (wifiDirect != null) localWifi.updateP2p(wifiDirect.snapshot());
          result.success(null); return;
        case "updateLocalWifiBeacon":
          if (localWifi == null) throw new IllegalStateException("Local Wi-Fi is unavailable");
          localWifi.updateBeacon(call.argument("signedBeacon"));
          result.success(null); return;
        case "probeLocalWifi":
          if (localWifi == null) throw new IllegalStateException("Local Wi-Fi is unavailable");
          Number probePort = call.argument("port");
          if (probePort == null) throw new IllegalArgumentException("Discovery port is required");
          localWifi.probe(call.argument("host"), probePort.intValue());
          result.success(null); return;
        case "openLocalWifiPeer":
          if (localWifi == null) throw new IllegalStateException("Local Wi-Fi is unavailable");
          Number peerPort = call.argument("port");
          if (peerPort == null) throw new IllegalArgumentException("Peer port is required");
          result.success(localWifi.openPeer(call.argument("host"), peerPort.intValue())); return;
        case "stopLocalWifi":
          if (localWifi != null) { localWifi.stop(); localWifi = null; }
          result.success(null); return;
        case "startNearby":
          byte[] beacon = call.argument("signedBeacon");
          String identityId = call.argument("identityId");
          Number tcpPort = call.argument("tcpPort"), ingressPort = call.argument("bluetoothIngressPort");
          if (beacon == null || beacon.length > 4096 || identityId == null || tcpPort == null || ingressPort == null) {
            result.error("arguments", "Invalid nearby transport configuration", null); return;
          }
          if (wifiDirect == null) wifiDirect = new WiFiDirectTransport(context, value -> {
            if (localWifi != null) localWifi.updateP2p(value);
            Map<String, Object> event = new HashMap<>(value);
            event.put("type", "state"); event.put("transport", "wifiDirect"); emitTransport(event);
          });
          if (bluetooth == null) bluetooth = new BleTransportBridge(context, this::emitTransport);
          bluetooth.setAppVisible(!RESUMED.isEmpty());
          wifiDirect.start(identityId, tcpPort.intValue());
          if (ingressPort.intValue() > 0) bluetooth.start(beacon, ingressPort.intValue());
          result.success(null); return;
        case "updateNearbyBeacon":
          byte[] updated = call.argument("signedBeacon");
          if (bluetooth != null && updated != null && updated.length <= 4096) bluetooth.updateBeacon(updated);
          result.success(null); return;
        case "refreshNearby":
          if (wifiDirect != null) wifiDirect.refresh();
          if (bluetooth != null) bluetooth.refresh();
          result.success(null); return;
        case "allowWifiDirect":
          if (wifiDirect != null) wifiDirect.setAutoConnectAllowed(
              Boolean.TRUE.equals(call.argument("allowed")) && (localWifi == null || !localWifi.isRunning()));
          result.success(null); return;
        case "stopNearby": stopNearby(); result.success(null); return;
        case "admitBluetooth":
          String routeId = call.argument("routeId");
          if (bluetooth != null && routeId != null) {
            if (Boolean.TRUE.equals(call.argument("accepted"))) bluetooth.accept(routeId);
            else bluetooth.reject(routeId);
          }
          result.success(null); return;
        case "requestNearbyPermissions": requestNearbyPermissions(result); return;
        case "enableBluetooth":
          BluetoothManager manager = (BluetoothManager)context.getSystemService(Context.BLUETOOTH_SERVICE);
          BluetoothAdapter adapter = manager == null ? null : manager.getAdapter();
          if (activity == null || adapter == null || (Build.VERSION.SDK_INT >= 31 && !granted(Manifest.permission.BLUETOOTH_CONNECT)) || adapter.isEnabled()) {
            result.success(null); return;
          }
          if (bluetoothEnableResult != null) { result.error("busy", "Bluetooth request already open", null); return; }
          bluetoothEnableResult = result;
          activity.startActivityForResult(new Intent(BluetoothAdapter.ACTION_REQUEST_ENABLE), BLUETOOTH_ENABLE); return;
        case "setDiscoveryActive": setDiscoveryActive(Boolean.TRUE.equals(call.argument("active"))); result.success(null); return;
        case "batterySettings":
          Intent settings = new Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS);
          settings.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
          context.startActivity(settings); result.success(null); return;
        case "requestNotifications":
          if (activity == null || Build.VERSION.SDK_INT < 33 || context.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED) {
            result.success(null); return;
          }
          if (permissionResult != null) { result.error("busy", "Permission request already open", null); return; }
          permissionResult = result;
          activity.requestPermissions(new String[]{Manifest.permission.POST_NOTIFICATIONS}, NOTIFICATIONS); return;
        case "exportReport":
          if (activity == null) { result.error("unavailable", "Open the app to export a report", null); return; }
          if (exportResult != null) { result.error("busy", "A report export is already open", null); return; }
          report = call.argument("report");
          if (report == null || report.length() > 8000000) { result.error("size", "Report is empty or too large", null); return; }
          exportResult = result;
          Intent save = new Intent(Intent.ACTION_CREATE_DOCUMENT);
          save.addCategory(Intent.CATEGORY_OPENABLE);
          save.setType("application/json");
          save.putExtra(Intent.EXTRA_TITLE, "PersianTrend-test-" + System.currentTimeMillis() + ".json");
          activity.startActivityForResult(save, EXPORT); return;
        default: result.notImplemented();
      }
    } catch (Exception ex) {
      if (call.method.equals("exportReport")) { report = null; exportResult = null; }
      if (call.method.equals("requestNotifications") || call.method.equals("requestNearbyPermissions")) permissionResult = null;
      if (call.method.equals("enableBluetooth")) bluetoothEnableResult = null;
      result.error("platform", ex.getClass().getSimpleName() + ": " + ex.getMessage(), null);
    }
  }

  private static void updateVisibility() {
    for (PilotPlatformPlugin instance : new ArrayList<>(INSTANCES)) {
      if (instance.bluetooth != null) instance.bluetooth.setAppVisible(!RESUMED.isEmpty());
    }
  }
  private void emitTransport(Map<String, Object> event) {
    if (channel != null && INSTANCES.contains(this)) channel.invokeMethod("transportEvent", event);
  }
  private void stopNearby() {
    if (wifiDirect != null) { wifiDirect.stop(); wifiDirect = null; }
    if (localWifi != null) localWifi.updateP2p(Collections.emptyMap());
    if (bluetooth != null) { bluetooth.stop(); bluetooth = null; }
  }
  private boolean granted(String permission) {
    return context.checkSelfPermission(permission) == PackageManager.PERMISSION_GRANTED;
  }
  private void requestNearbyPermissions(MethodChannel.Result result) {
    if (activity == null) { result.success(null); return; }
    if (permissionResult != null) { result.error("busy", "Permission request already open", null); return; }
    ArrayList<String> needed = new ArrayList<>();
    if (Build.VERSION.SDK_INT >= 31) {
      for (String permission : new String[]{Manifest.permission.BLUETOOTH_SCAN, Manifest.permission.BLUETOOTH_ADVERTISE, Manifest.permission.BLUETOOTH_CONNECT}) {
        if (!granted(permission)) needed.add(permission);
      }
    }
    if (Build.VERSION.SDK_INT >= 33) {
      if (!granted(Manifest.permission.NEARBY_WIFI_DEVICES)) needed.add(Manifest.permission.NEARBY_WIFI_DEVICES);
    } else if (!granted(Manifest.permission.ACCESS_FINE_LOCATION)) {
      needed.add(Manifest.permission.ACCESS_COARSE_LOCATION);
      needed.add(Manifest.permission.ACCESS_FINE_LOCATION);
    }
    if (needed.isEmpty()) { result.success(null); return; }
    permissionResult = result;
    activity.requestPermissions(needed.toArray(new String[0]), NEARBY);
  }

  private void setDiscoveryActive(boolean active) {
    if (active && (discoveryLock == null || !discoveryLock.isHeld())) {
      WifiManager wifi = (WifiManager) context.getApplicationContext().getSystemService(Context.WIFI_SERVICE);
      if (wifi != null) {
        WifiManager.MulticastLock candidate = wifi.createMulticastLock("PersianTrend:peer-discovery");
        candidate.setReferenceCounted(false);
        candidate.acquire();
        discoveryLock = candidate;
      }
    } else if (!active && discoveryLock != null) {
      try { if (discoveryLock.isHeld()) discoveryLock.release(); }
      finally { discoveryLock = null; }
    }
  }

  private Map<String, Object> state() throws Exception {
    Map<String, Object> data = new HashMap<>();
    PowerManager power = (PowerManager) context.getSystemService(Context.POWER_SERVICE);
    KeyguardManager keyguard = (KeyguardManager) context.getSystemService(Context.KEYGUARD_SERVICE);
    ConnectivityManager connectivity = (ConnectivityManager) context.getSystemService(Context.CONNECTIVITY_SERVICE);
    Network active = connectivity.getActiveNetwork();
    NetworkCapabilities caps = connectivity.getNetworkCapabilities(active);
    data.put("platform", "android");
    data.put("manufacturer", Build.MANUFACTURER);
    data.put("model", Build.MODEL);
    data.put("osVersion", Build.VERSION.RELEASE);
    data.put("sdk", Build.VERSION.SDK_INT);
    data.put("targetSdk", context.getApplicationInfo().targetSdkVersion);
    data.put("wallTimeMs", System.currentTimeMillis());
    data.put("elapsedRealtimeMs", SystemClock.elapsedRealtime());
    int boot = Settings.Global.getInt(context.getContentResolver(), Settings.Global.BOOT_COUNT, -1);
    data.put("bootId", boot >= 0 ? Integer.toString(boot) : null);
    data.put("isLocked", keyguard.isDeviceLocked());
    data.put("lockStateKnown", true);
    data.put("screenOn", power.isInteractive());
    data.put("powerSave", power.isPowerSaveMode());
    data.put("deviceIdle", power.isDeviceIdleMode());
    data.put("batteryExempt", power.isIgnoringBatteryOptimizations(context.getPackageName()));
    data.put("lowPowerStandby", Build.VERSION.SDK_INT >= 33 && power.isLowPowerStandbyEnabled());
    data.put("notificationsEnabled", ((NotificationManager)context.getSystemService(Context.NOTIFICATION_SERVICE)).areNotificationsEnabled());
    data.put("multicastLockHeld", discoveryLock != null && discoveryLock.isHeld());
    if (wifiDirect != null) data.put("wifiDirect", wifiDirect.snapshot());
    if (bluetooth != null) data.put("bluetooth", bluetooth.snapshot());
    if (localWifi != null) data.put("localWifi", localWifi.snapshot());
    data.put("network", caps == null ? "none" : caps.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR) ? "cellular" : caps.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) ? "wifi" : "other");
    data.put("internetValidated", caps != null && caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED));
    Intent battery = context.registerReceiver(null, new IntentFilter(Intent.ACTION_BATTERY_CHANGED));
    if (battery != null) {
      int level = battery.getIntExtra(BatteryManager.EXTRA_LEVEL, -1);
      int scale = battery.getIntExtra(BatteryManager.EXTRA_SCALE, 100);
      data.put("batteryPercent", scale > 0 ? level * 100 / scale : -1);
      data.put("charging", battery.getIntExtra(BatteryManager.EXTRA_PLUGGED, 0) != 0);
    }
    ArrayList<String> addresses = new ArrayList<>();
    try {
      java.util.Enumeration<NetworkInterface> interfaces = NetworkInterface.getNetworkInterfaces();
      if (interfaces != null) for (NetworkInterface iface : Collections.list(interfaces)) {
        if (!iface.isUp() || iface.isLoopback()) continue;
        for (InetAddress addr : Collections.list(iface.getInetAddresses())) {
          if (addr.isLoopbackAddress() || addr.isLinkLocalAddress()) continue;
          String host = addr.getHostAddress();
          if (host != null && !host.contains("%") && addresses.size() < 16) addresses.add(host);
        }
      }
    } catch (Exception ignored) {
      data.put("addressDiscoveryAvailable", false);
    }
    data.put("addresses", addresses);
    return data;
  }
  @Override public boolean onRequestPermissionsResult(int request, String[] permissions, int[] grants) {
    if (request != NOTIFICATIONS && request != NEARBY) return false;
    if (permissionResult != null) { permissionResult.success(null); permissionResult = null; }
    return true;
  }
  @Override public boolean onActivityResult(int request, int resultCode, Intent data) {
    if (request == BLUETOOTH_ENABLE) {
      if (bluetoothEnableResult != null) { bluetoothEnableResult.success(null); bluetoothEnableResult = null; }
      return true;
    }
    if (request != EXPORT) return false;
    MethodChannel.Result callback = exportResult;
    exportResult = null;
    try {
      if (callback == null) return true;
      if (resultCode != Activity.RESULT_OK || data == null || data.getData() == null) { callback.success(false); return true; }
      try (OutputStream stream = context.getContentResolver().openOutputStream(data.getData(), "wt")) {
        if (stream == null) throw new IllegalStateException("Cannot write selected document");
        stream.write(report.getBytes(StandardCharsets.UTF_8));
        stream.flush();
      }
      callback.success(true);
    } catch (Exception ex) { if (callback != null) callback.error("export", ex.getMessage(), null); }
    finally { report = null; }
    return true;
  }
}
