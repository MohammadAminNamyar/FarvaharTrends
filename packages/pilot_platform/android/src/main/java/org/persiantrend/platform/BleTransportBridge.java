package org.persiantrend.platform;

import android.Manifest;
import android.bluetooth.BluetoothAdapter;
import android.bluetooth.BluetoothDevice;
import android.bluetooth.BluetoothGatt;
import android.bluetooth.BluetoothGattCallback;
import android.bluetooth.BluetoothGattCharacteristic;
import android.bluetooth.BluetoothGattDescriptor;
import android.bluetooth.BluetoothGattServer;
import android.bluetooth.BluetoothGattServerCallback;
import android.bluetooth.BluetoothGattService;
import android.bluetooth.BluetoothManager;
import android.bluetooth.BluetoothProfile;
import android.bluetooth.BluetoothStatusCodes;
import android.bluetooth.le.AdvertiseCallback;
import android.bluetooth.le.AdvertiseData;
import android.bluetooth.le.AdvertiseSettings;
import android.bluetooth.le.BluetoothLeAdvertiser;
import android.bluetooth.le.BluetoothLeScanner;
import android.bluetooth.le.ScanCallback;
import android.bluetooth.le.ScanFilter;
import android.bluetooth.le.ScanResult;
import android.bluetooth.le.ScanSettings;
import android.content.Context;
import android.content.pm.PackageManager;
import android.os.Build;
import android.os.Handler;
import android.os.Looper;
import android.os.ParcelUuid;
import android.os.SystemClock;
import android.util.Base64;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.net.InetAddress;
import java.net.InetSocketAddress;
import java.net.ServerSocket;
import java.net.Socket;
import java.security.SecureRandom;
import java.util.ArrayDeque;
import java.util.Arrays;
import java.util.Collections;
import java.util.HashMap;
import java.util.LinkedHashMap;
import java.util.Map;
import java.util.UUID;
import java.util.concurrent.ArrayBlockingQueue;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.RejectedExecutionException;
import java.util.concurrent.TimeUnit;

/**
 * One experimental BLE GATT byte tunnel. The bridge never interprets private
 * keys, TLS, channels, or news. Dart must verify the signed public beacon and
 * admit its certificate before calling accept(). Both endpoints then run the
 * existing mutually authenticated TLS protocol across these bytes.
 *
 * All Bluetooth state is serialized on the main handler; blocking socket work
 * runs on three workers. DATA uses an 8 KiB receive-credit window and bounded
 * queues. Android GATT operations are serialized and have explicit timeouts.
 * An ATT acknowledgement is not a durable news receipt.
 */
public final class BleTransportBridge {
  public interface Listener { void onEvent(Map<String, Object> event); }
  public static final UUID SERVICE = UUID.fromString("8af06310-ea52-489e-b259-31f68fbb7045");
  public static final UUID RX = UUID.fromString("8af06311-ea52-489e-b259-31f68fbb7045");
  public static final UUID TX = UUID.fromString("8af06312-ea52-489e-b259-31f68fbb7045");
  private static final UUID CCCD = UUID.fromString("00002902-0000-1000-8000-00805f9b34fb");
  private static final ParcelUuid PARCEL_SERVICE = new ParcelUuid(SERVICE);
  private static final int OP_TIMEOUT_MS = 20000, SETUP_TIMEOUT_MS = 90000;
  private static final int ADMISSION_TIMEOUT_MS = 30000, SESSION_MS = 180000;
  private static final byte[] EMPTY = new byte[0];
  private final Context context;
  private final Listener listener;
  private final Handler main = new Handler(Looper.getMainLooper());
  private final BleRuntime.Scheduler deadlines = new BleRuntime.Scheduler() {
    @Override public void postDelayed(Runnable callback, long delayMs) { main.postDelayed(callback, delayMs); }
    @Override public void remove(Runnable callback) { main.removeCallbacks(callback); }
  };
  private final SecureRandom random = new SecureRandom();
  private final LinkedHashMap<String, Long> retryAfter = new LinkedHashMap<>();
  private volatile Map<String, Object> state = Collections.singletonMap("state", "stopped");
  private BluetoothAdapter adapter;
  private BluetoothLeScanner scanner;
  private BluetoothLeAdvertiser advertiser;
  private BluetoothGattServer server;
  private BluetoothGattCharacteristic serverTx;
  private ExecutorService io;
  private byte[] beacon = EMPTY, token = EMPTY;
  private int localPort, generation, scanAttempt, advertiseAttempt;
  private boolean running, appVisible, scanning, advertising, serviceReady;
  private Link link;

  public BleTransportBridge(Context context, Listener listener) {
    this.context = context.getApplicationContext();
    this.listener = listener;
  }

  public void start(byte[] signedBeacon, int localTlsPort) {
    BleWire.hello(signedBeacon);
    if (localTlsPort < 1 || localTlsPort > 65535) throw new IllegalArgumentException("Invalid TLS ingress port");
    byte[] copy = signedBeacon.clone();
    main.post(() -> {
      stopInternal();
      running = true;
      generation++;
      beacon = copy;
      localPort = localTlsPort;
      token = new byte[8];
      random.nextBytes(token);
      io = BleRuntime.newIoExecutor();
      initializeRadio();
    });
  }

  public void updateBeacon(byte[] signedBeacon) {
    BleWire.hello(signedBeacon);
    byte[] copy = signedBeacon.clone();
    main.post(() -> beacon = copy);
  }

  /** API 29/30 discovery is foreground-only unless background location exists. */
  public void setAppVisible(boolean visible) {
    main.post(() -> {
      appVisible = visible;
      if (!running) return;
      if (!mayScan()) stopScan();
      refreshInternal();
    });
  }

  public void stop() { main.post(this::stopInternal); }

  /** Recover from an explicit permission/radio change without disrupting a link. */
  public void refresh() { main.post(this::refreshInternal); }

  private void refreshInternal() {
    if (!running) return;
    try {
      boolean permissions = Build.VERSION.SDK_INT >= 31
          ? permitted(Manifest.permission.BLUETOOTH_SCAN) && permitted(Manifest.permission.BLUETOOTH_CONNECT)
          : permitted(Manifest.permission.ACCESS_FINE_LOCATION);
      if (!permissions || adapter == null || !adapter.isEnabled() || scanner == null) {
        resetRadio();
        initializeRadio();
        return;
      }
      if (link != null) {
        publishState(link.socket == null ? "connecting" : "connected", null);
        return;
      }
      // ADVERTISE may be granted later than SCAN/CONNECT. Add the peripheral
      // role on the next refresh, without tearing down a healthy active link.
      if (advertiser == null && server == null && adapter.isMultipleAdvertisementSupported() &&
          (Build.VERSION.SDK_INT < 31 || permitted(Manifest.permission.BLUETOOTH_ADVERTISE))) {
        resetRadio(); initializeRadio(); return;
      }
      startScan(); startAdvertising();
      publishState(scanning || advertising ? "discovering" : !mayScan() ? "foreground_only" : "unavailable", null);
    } catch (RuntimeException error) {
      resetRadio();
      publishState("unavailable", error.getClass().getSimpleName());
    }
  }

  public void accept(String routeId) {
    main.post(() -> {
      Link current = link;
      if (!matches(current, routeId) || current.remoteBeacon == null || current.accepted) return;
      current.accepted = true;
      current.admissionDeadline.cancel();
      if (current.central) {
        current.readyPending = true;
        pump(current);
        maybeExposeEndpoint(current);
      } else {
        connectIngress(current);
      }
    });
  }

  public void reject(String routeId) {
    main.post(() -> { if (matches(link, routeId)) closeLink(link, "admission_rejected"); });
  }

  public Map<String, Object> snapshot() { return new HashMap<>(state); }

  private boolean permitted(String permission) {
    return context.checkSelfPermission(permission) == PackageManager.PERMISSION_GRANTED;
  }

  private boolean mayScan() {
    return Build.VERSION.SDK_INT < 29 || Build.VERSION.SDK_INT > 30 || appVisible ||
        permitted(Manifest.permission.ACCESS_BACKGROUND_LOCATION);
  }

  private void initializeRadio() {
    if (!running) return;
    try {
      if (!context.getPackageManager().hasSystemFeature(PackageManager.FEATURE_BLUETOOTH_LE)) {
        publishState("unsupported", "BLE hardware unavailable"); return;
      }
      if (Build.VERSION.SDK_INT >= 31 &&
          (!permitted(Manifest.permission.BLUETOOTH_SCAN) || !permitted(Manifest.permission.BLUETOOTH_CONNECT))) {
        publishState("permission_required", "Nearby devices permission required"); return;
      }
      if (Build.VERSION.SDK_INT < 31 && !permitted(Manifest.permission.ACCESS_FINE_LOCATION)) {
        publishState("permission_required", "Location permission required for BLE discovery on this Android version"); return;
      }
      BluetoothManager manager = (BluetoothManager) context.getSystemService(Context.BLUETOOTH_SERVICE);
      adapter = manager == null ? null : manager.getAdapter();
      if (adapter == null) { publishState("unsupported", "Bluetooth adapter unavailable"); return; }
      if (!adapter.isEnabled()) { publishState("bluetooth_off", "Enable Bluetooth in Android settings"); return; }
      scanner = adapter.getBluetoothLeScanner();
      if (scanner == null) { publishState("unavailable", "BLE scanner unavailable"); return; }
      boolean canAdvertise = Build.VERSION.SDK_INT < 31 || permitted(Manifest.permission.BLUETOOTH_ADVERTISE);
      if (canAdvertise && adapter.isMultipleAdvertisementSupported()) {
        advertiser = adapter.getBluetoothLeAdvertiser();
      }
      if (advertiser != null) {
        server = manager.openGattServer(context, new ServerCallback(generation));
        if (server != null) {
          BluetoothGattService service = new BluetoothGattService(SERVICE, BluetoothGattService.SERVICE_TYPE_PRIMARY);
          service.addCharacteristic(new BluetoothGattCharacteristic(RX,
              BluetoothGattCharacteristic.PROPERTY_WRITE, BluetoothGattCharacteristic.PERMISSION_WRITE));
          serverTx = new BluetoothGattCharacteristic(TX,
              BluetoothGattCharacteristic.PROPERTY_INDICATE, BluetoothGattCharacteristic.PERMISSION_READ);
          serverTx.addDescriptor(new BluetoothGattDescriptor(CCCD,
              BluetoothGattDescriptor.PERMISSION_READ | BluetoothGattDescriptor.PERMISSION_WRITE));
          service.addCharacteristic(serverTx);
          if (!server.addService(service)) { server.close(); server = null; advertiser = null; }
        } else advertiser = null;
      }
      startScan();
      publishState(scanning || advertising ? "discovering" : !mayScan() ? "foreground_only" : "initializing", null);
    } catch (RuntimeException error) {
      publishState("unavailable", error.getClass().getSimpleName());
    }
  }

  private void startScan() {
    if (!running || scanning || scanner == null || link != null || !mayScan()) return;
    try {
      scanner.startScan(Collections.singletonList(new ScanFilter.Builder().setServiceUuid(PARCEL_SERVICE).build()),
          new ScanSettings.Builder().setScanMode(ScanSettings.SCAN_MODE_BALANCED).setReportDelay(0).build(),
          scanCallback = makeScanCallback(generation, ++scanAttempt));
      scanning = true;
    } catch (RuntimeException error) { publishState("scan_failed", error.getClass().getSimpleName()); }
  }

  private void stopScan() {
    if (scanning && scanner != null) {
      try { scanner.stopScan(scanCallback); } catch (RuntimeException ignored) {}
    }
    scanning = false;
    scanAttempt++;
  }

  private void startAdvertising() {
    if (!running || advertising || advertiser == null || !serviceReady || link != null) return;
    try {
      // 21-byte primary advertisement; 26-byte scan response. No peer name/MAC.
      AdvertiseData data = new AdvertiseData.Builder().addServiceUuid(PARCEL_SERVICE).build();
      AdvertiseData response = new AdvertiseData.Builder().addServiceData(PARCEL_SERVICE, token).build();
      advertiser.startAdvertising(new AdvertiseSettings.Builder().setConnectable(true)
          .setAdvertiseMode(AdvertiseSettings.ADVERTISE_MODE_BALANCED).setTimeout(0).build(),
          data, response, advertiseCallback = makeAdvertiseCallback(generation, ++advertiseAttempt));
      advertising = true;
    } catch (RuntimeException error) { publishState("advertise_failed", error.getClass().getSimpleName()); }
  }

  private void stopAdvertising() {
    if (advertising && advertiser != null) {
      try { advertiser.stopAdvertising(advertiseCallback); } catch (RuntimeException ignored) {}
    }
    advertising = false;
    advertiseAttempt++;
  }

  private AdvertiseCallback advertiseCallback;
  private ScanCallback scanCallback;
  private AdvertiseCallback makeAdvertiseCallback(int session, int attempt) {
    return new AdvertiseCallback() {
      @Override public void onStartSuccess(AdvertiseSettings settings) {
        main.post(() -> {
          if (running && session == generation && attempt == advertiseAttempt) publishState(link == null ? "discovering" : "connecting", null);
        });
      }
      @Override public void onStartFailure(int code) {
        main.post(() -> {
          if (running && session == generation && attempt == advertiseAttempt) {
            advertising = false; publishState("advertise_failed", "Android advertising error " + code);
          }
        });
      }
    };
  }
  private ScanCallback makeScanCallback(int session, int attempt) {
    return new ScanCallback() {
      @Override public void onScanResult(int type, ScanResult result) {
        main.post(() -> { if (running && session == generation && attempt == scanAttempt) found(result); });
      }
      @Override public void onScanFailed(int code) {
        main.post(() -> {
          if (running && session == generation && attempt == scanAttempt) {
            scanning = false; publishState("scan_failed", "Android scan error " + code);
          }
        });
      }
    };
  }

  private void found(ScanResult result) {
    if (!running || link != null || result.getScanRecord() == null) return;
    byte[] remoteToken = result.getScanRecord().getServiceData(PARCEL_SERVICE);
    if (remoteToken == null || remoteToken.length != 8 || Arrays.equals(token, remoteToken)) return;
    // When both support advertising, exactly one session token initiates.
    if (advertising && compare(token, remoteToken) >= 0) return;
    BluetoothDevice device = result.getDevice();
    try {
      String address = device.getAddress();
      Long retry = retryAfter.get(address);
      if (retry != null && retry > SystemClock.elapsedRealtime()) return;
      Link current = new Link(device, true, beacon, deadlines);
      link = current;
      stopScan(); stopAdvertising();
      armSetup(current);
      current.gatt = device.connectGatt(context, false, new ClientCallback(current),
          BluetoothDevice.TRANSPORT_LE, BluetoothDevice.PHY_LE_1M_MASK, main);
      if (current.gatt == null) { closeLink(current, "gatt_connect_failed"); return; }
      armOperation(current, "connect");
      publishState("connecting", null);
    } catch (RuntimeException error) { if (link != null) closeLink(link, "gatt_connect_failed"); }
  }

  private static int compare(byte[] left, byte[] right) {
    for (int i = 0; i < left.length; i++) {
      int difference = (left[i] & 255) - (right[i] & 255);
      if (difference != 0) return difference;
    }
    return 0;
  }

  private final class ClientCallback extends BluetoothGattCallback {
    private final Link current;
    ClientCallback(Link current) { this.current = current; }
    private boolean alive(BluetoothGatt gatt) { return isCurrent(current) && current.gatt == gatt; }
    @Override public void onConnectionStateChange(BluetoothGatt gatt, int status, int newState) {
      if (!alive(gatt)) return;
      if (status != BluetoothGatt.GATT_SUCCESS || newState == BluetoothProfile.STATE_DISCONNECTED) {
        closeLink(current, "gatt_disconnected"); return;
      }
      if (newState != BluetoothProfile.STATE_CONNECTED) return;
      completeOperation(current);
      try {
        if (gatt.requestMtu(517)) armOperation(current, "mtu"); else discover(current);
      } catch (RuntimeException error) { closeLink(current, "mtu_failed"); }
    }
    @Override public void onMtuChanged(BluetoothGatt gatt, int mtu, int status) {
      if (!alive(gatt) || !"mtu".equals(current.operation)) return;
      completeOperation(current);
      if (status == BluetoothGatt.GATT_SUCCESS) current.payloadSize = payloadSize(mtu);
      discover(current);
    }
    @Override public void onServicesDiscovered(BluetoothGatt gatt, int status) {
      if (!alive(gatt) || !"services".equals(current.operation)) return;
      completeOperation(current);
      try {
        BluetoothGattService service = gatt.getService(SERVICE);
        current.rx = service == null ? null : service.getCharacteristic(RX);
        current.tx = service == null ? null : service.getCharacteristic(TX);
        BluetoothGattDescriptor descriptor = current.tx == null ? null : current.tx.getDescriptor(CCCD);
        if (status != BluetoothGatt.GATT_SUCCESS || current.rx == null || descriptor == null ||
            (current.rx.getProperties() & BluetoothGattCharacteristic.PROPERTY_WRITE) == 0 ||
            (current.tx.getProperties() & BluetoothGattCharacteristic.PROPERTY_INDICATE) == 0 ||
            !gatt.setCharacteristicNotification(current.tx, true)) {
          closeLink(current, "gatt_service_missing"); return;
        }
        armOperation(current, "subscribe");
        boolean ok;
        if (Build.VERSION.SDK_INT >= 33) {
          ok = gatt.writeDescriptor(descriptor, BluetoothGattDescriptor.ENABLE_INDICATION_VALUE) == BluetoothStatusCodes.SUCCESS;
        } else {
          descriptor.setValue(BluetoothGattDescriptor.ENABLE_INDICATION_VALUE);
          ok = gatt.writeDescriptor(descriptor);
        }
        if (!ok) closeLink(current, "gatt_subscribe_failed");
      } catch (RuntimeException error) { closeLink(current, "gatt_subscribe_failed"); }
    }
    @Override public void onDescriptorWrite(BluetoothGatt gatt, BluetoothGattDescriptor descriptor, int status) {
      if (!alive(gatt) || !"subscribe".equals(current.operation) || !CCCD.equals(descriptor.getUuid())) return;
      completeOperation(current);
      if (status != BluetoothGatt.GATT_SUCCESS) { closeLink(current, "gatt_subscribe_failed"); return; }
      startHello(current);
    }
    @Override public void onCharacteristicWrite(BluetoothGatt gatt, BluetoothGattCharacteristic characteristic, int status) {
      if (!alive(gatt) || !"write".equals(current.operation) || !RX.equals(characteristic.getUuid())) return;
      completeOperation(current);
      current.inFlight = null;
      if (status != BluetoothGatt.GATT_SUCCESS) { closeLink(current, "gatt_write_failed"); return; }
      pump(current);
    }
    @Override public void onCharacteristicChanged(BluetoothGatt gatt, BluetoothGattCharacteristic characteristic, byte[] value) {
      if (alive(gatt) && TX.equals(characteristic.getUuid())) receive(current, value.clone());
    }
    @Override public void onCharacteristicChanged(BluetoothGatt gatt, BluetoothGattCharacteristic characteristic) {
      if (Build.VERSION.SDK_INT < 33 && alive(gatt) && TX.equals(characteristic.getUuid())) {
        byte[] value = characteristic.getValue();
        receive(current, value == null ? null : value.clone());
      }
    }
  }

  private void discover(Link current) {
    if (!isCurrent(current)) return;
    try {
      armOperation(current, "services");
      if (!current.gatt.discoverServices()) closeLink(current, "gatt_discovery_failed");
    } catch (RuntimeException error) { closeLink(current, "gatt_discovery_failed"); }
  }

  private final class ServerCallback extends BluetoothGattServerCallback {
    private final int session;
    ServerCallback(int session) { this.session = session; }
    private void post(Runnable task) {
      main.post(() -> { if (running && generation == session && server != null) task.run(); });
    }
    @Override public void onServiceAdded(int status, BluetoothGattService service) {
      post(() -> {
        if (!running || server == null || !SERVICE.equals(service.getUuid())) return;
        serviceReady = status == BluetoothGatt.GATT_SUCCESS;
        if (serviceReady) startAdvertising(); else publishState("advertise_failed", "GATT service registration failed");
      });
    }
    @Override public void onConnectionStateChange(BluetoothDevice device, int status, int newState) {
      post(() -> {
        if (!running || server == null) return;
        if (newState == BluetoothProfile.STATE_DISCONNECTED) {
          if (samePeripheral(link, device)) closeLink(link, "gatt_disconnected");
          return;
        }
        if (newState != BluetoothProfile.STATE_CONNECTED || status != BluetoothGatt.GATT_SUCCESS) return;
        if (link != null) {
          // Android reports this server callback for the device's shared ACL,
          // including our own outbound GATT client. It is not a second inbound
          // application stream; cancelling it can tear down our central link.
          if (link.central && link.device.equals(device)) return;
          if (!samePeripheral(link, device)) try { server.cancelConnection(device); } catch (RuntimeException ignored) {}
          return;
        }
        link = new Link(device, false, beacon, deadlines);
        stopScan(); stopAdvertising();
        armSetup(link);
        publishState("connecting", null);
      });
    }
    @Override public void onMtuChanged(BluetoothDevice device, int mtu) {
      post(() -> { if (samePeripheral(link, device) && !link.helloStarted) link.payloadSize = payloadSize(mtu); });
    }
    @Override public void onDescriptorWriteRequest(BluetoothDevice device, int id, BluetoothGattDescriptor descriptor,
        boolean prepared, boolean responseNeeded, int offset, byte[] value) {
      byte[] copy = value == null ? EMPTY : value.clone();
      post(() -> {
        boolean ok = samePeripheral(link, device) && CCCD.equals(descriptor.getUuid()) &&
            TX.equals(descriptor.getCharacteristic().getUuid()) && !prepared && offset == 0 &&
            Arrays.equals(copy, BluetoothGattDescriptor.ENABLE_INDICATION_VALUE);
        if (responseNeeded) respond(device, id, ok ? BluetoothGatt.GATT_SUCCESS : BluetoothGatt.GATT_REQUEST_NOT_SUPPORTED);
        if (ok) startHello(link);
      });
    }
    @Override public void onDescriptorReadRequest(BluetoothDevice device, int id, int offset, BluetoothGattDescriptor descriptor) {
      post(() -> {
        if (server == null) return;
        try { server.sendResponse(device, id, BluetoothGatt.GATT_REQUEST_NOT_SUPPORTED, offset, null); } catch (RuntimeException ignored) {}
      });
    }
    @Override public void onCharacteristicReadRequest(BluetoothDevice device, int id, int offset, BluetoothGattCharacteristic characteristic) {
      post(() -> respond(device, id, BluetoothGatt.GATT_REQUEST_NOT_SUPPORTED));
    }
    @Override public void onCharacteristicWriteRequest(BluetoothDevice device, int id, BluetoothGattCharacteristic characteristic,
        boolean prepared, boolean responseNeeded, int offset, byte[] value) {
      byte[] copy = value == null ? null : value.clone();
      post(() -> {
        boolean ok = samePeripheral(link, device) && RX.equals(characteristic.getUuid()) && !prepared &&
            offset == 0 && responseNeeded && link.helloStarted;
        if (ok) ok = receive(link, copy);
        if (responseNeeded) respond(device, id, ok ? BluetoothGatt.GATT_SUCCESS : BluetoothGatt.GATT_REQUEST_NOT_SUPPORTED);
      });
    }
    @Override public void onExecuteWrite(BluetoothDevice device, int id, boolean execute) {
      post(() -> respond(device, id, BluetoothGatt.GATT_REQUEST_NOT_SUPPORTED));
    }
    @Override public void onNotificationSent(BluetoothDevice device, int status) {
      post(() -> {
        Link current = link;
        if (!samePeripheral(current, device) || !"indicate".equals(current.operation)) return;
        completeOperation(current);
        current.inFlight = null;
        if (status != BluetoothGatt.GATT_SUCCESS) closeLink(current, "gatt_indication_failed"); else pump(current);
      });
    }
  }

  private void respond(BluetoothDevice device, int id, int status) {
    if (server != null) try { server.sendResponse(device, id, status, 0, null); } catch (RuntimeException ignored) {}
  }

  private static int payloadSize(int mtu) { return Math.max(17, Math.min(BleWire.MAX_VALUE, mtu - 3) - 3); }

  private void startHello(Link current) {
    if (!isCurrent(current) || current.helloStarted) return;
    current.helloStarted = true;
    byte[] hello = BleWire.hello(current.localBeacon);
    for (int offset = 0; offset < hello.length; offset += current.payloadSize) {
      current.hello.add(Arrays.copyOfRange(hello, offset, Math.min(hello.length, offset + current.payloadSize)));
    }
    pump(current);
  }

  private boolean receive(Link current, byte[] bytes) {
    if (!isCurrent(current)) return false;
    try {
      if (bytes == null || bytes.length > current.payloadSize + 3) throw new IllegalArgumentException("BLE value exceeds negotiated MTU");
      BleWire.Frame frame = current.decoder.read(bytes);
      if (frame.type == BleWire.HELLO) {
        if (frame.payload == null) return true;
        current.remoteBeacon = frame.payload;
        Map<String, Object> event = event("peerDiscovered", current);
        event.put("role", current.central ? "central" : "peripheral");
        event.put("beaconBase64", Base64.encodeToString(frame.payload, Base64.NO_WRAP));
        emit(event);
        current.admissionDeadline.arm(ADMISSION_TIMEOUT_MS,
            () -> { if (isCurrent(current) && !current.accepted) closeLink(current, "admission_timeout"); });
      } else if (frame.type == BleWire.READY) {
        if (current.remoteReady) throw new IllegalArgumentException("Duplicate BLE ready");
        current.remoteReady = true;
        current.sendCredit = BleWire.number(frame.payload);
        maybeExposeEndpoint(current);
        pump(current);
      } else if (frame.type == BleWire.CREDIT) {
        if (!current.remoteReady) throw new IllegalArgumentException("BLE credit before ready");
        int credit = BleWire.number(frame.payload);
        if (current.sendCredit + credit > BleWire.WINDOW) throw new IllegalArgumentException("BLE credit overflow");
        current.sendCredit += credit;
        pump(current);
      } else {
        if (!current.accepted || !current.readySent || !current.remoteReady || current.socket == null ||
            frame.payload.length > current.receiveCredit || !current.incoming.offer(frame.payload)) {
          throw new IllegalArgumentException("BLE data before ready or receive window exceeded");
        }
        current.receiveCredit -= frame.payload.length;
      }
      return true;
    } catch (RuntimeException error) { closeLink(current, "malformed_ble_frame"); return false; }
  }

  private void pump(Link current) {
    if (!isCurrent(current) || !current.helloStarted || current.inFlight != null || current.operation != null) return;
    int type;
    byte[] payload;
    if (!current.hello.isEmpty()) { type = BleWire.HELLO; payload = current.hello.removeFirst(); }
    else if (current.readyPending && !current.readySent) {
      type = BleWire.READY; payload = BleWire.number(BleWire.WINDOW); current.readySent = true;
      current.receiveCredit = BleWire.WINDOW;
    } else if (current.creditPending > 0) {
      type = BleWire.CREDIT; payload = BleWire.number(current.creditPending);
      current.receiveCredit += current.creditPending;
      current.creditPending = 0;
    } else {
      if (!current.accepted || !current.readySent || !current.remoteReady) return;
      payload = current.outgoing.peek();
      if (payload == null || payload.length > current.sendCredit) return;
      current.outgoing.poll();
      type = BleWire.DATA;
      current.sendCredit -= payload.length;
    }
    byte[] value = BleWire.frame(type, current.sendSequence++, payload);
    current.inFlight = value;
    try {
      boolean ok;
      if (current.central) {
        armOperation(current, "write");
        if (Build.VERSION.SDK_INT >= 33) {
          ok = current.gatt.writeCharacteristic(current.rx, value, BluetoothGattCharacteristic.WRITE_TYPE_DEFAULT) == BluetoothStatusCodes.SUCCESS;
        } else {
          current.rx.setWriteType(BluetoothGattCharacteristic.WRITE_TYPE_DEFAULT);
          current.rx.setValue(value);
          ok = current.gatt.writeCharacteristic(current.rx);
        }
      } else {
        armOperation(current, "indicate");
        if (Build.VERSION.SDK_INT >= 33) {
          ok = server.notifyCharacteristicChanged(current.device, serverTx, true, value) == BluetoothStatusCodes.SUCCESS;
        } else {
          serverTx.setValue(value);
          ok = server.notifyCharacteristicChanged(current.device, serverTx, true);
        }
      }
      if (!ok) closeLink(current, "gatt_send_failed");
    } catch (RuntimeException error) { closeLink(current, "gatt_send_failed"); }
  }

  private void connectIngress(Link current) {
    int ingressPort = localPort;
    runIo(current, () -> {
      if (current.closed) return;
      Socket socket = new Socket();
      current.connectingSocket = socket;
      if (current.closed) { close(socket); return; }
      try {
        socket.connect(new InetSocketAddress(InetAddress.getByName("127.0.0.1"), ingressPort), 10000);
        socket.setTcpNoDelay(true);
        main.post(() -> {
          current.connectingSocket = null;
          if (!isCurrent(current)) { close(socket); return; }
          attachSocket(current, socket);
          current.readyPending = true;
          pump(current);
        });
      } catch (IOException error) {
        close(socket);
        main.post(() -> { if (isCurrent(current)) closeLink(current, "local_ingress_failed"); });
      }
    });
  }

  private void maybeExposeEndpoint(Link current) {
    if (!isCurrent(current) || !current.central || !current.accepted || !current.remoteReady || current.endpointPending) return;
    current.endpointPending = true;
    runIo(current, () -> {
      if (current.closed) return;
      ServerSocket endpoint = null;
      try {
        endpoint = new ServerSocket();
        endpoint.bind(new InetSocketAddress(InetAddress.getByName("127.0.0.1"), 0), 1);
        endpoint.setSoTimeout(30000);
        current.endpoint = endpoint;
        if (current.closed) return;
        int port = endpoint.getLocalPort();
        main.post(() -> {
          if (!isCurrent(current)) return;
          Map<String, Object> event = event("endpointReady", current);
          event.put("host", "127.0.0.1"); event.put("port", port);
          event.put("beaconBase64", Base64.encodeToString(current.remoteBeacon, Base64.NO_WRAP));
          emit(event);
        });
        Socket socket = endpoint.accept();
        socket.setTcpNoDelay(true);
        endpoint.close();
        main.post(() -> { if (isCurrent(current)) attachSocket(current, socket); else close(socket); });
      } catch (IOException error) {
        main.post(() -> { if (isCurrent(current)) closeLink(current, "local_endpoint_failed"); });
      } finally { close(endpoint); }
    });
  }

  private void attachSocket(Link current, Socket socket) {
    if (!isCurrent(current)) { close(socket); return; }
    current.socket = socket;
    current.setupDeadline.cancel();
    current.attachedAtMs = SystemClock.elapsedRealtime();
    publishState("connected", null);
    current.sessionDeadline.arm(SESSION_MS,
        () -> { if (isCurrent(current)) closeLink(current, "session_rotation"); });
    runIo(current, () -> {
      try {
        InputStream input = socket.getInputStream();
        byte[] buffer = new byte[current.payloadSize];
        int count;
        while (!current.closed && (count = input.read(buffer)) != -1) {
          if (count == 0) continue;
          byte[] bytes = Arrays.copyOf(buffer, count);
          while (!current.closed && !current.outgoing.offer(bytes, 1, TimeUnit.SECONDS)) { /* TCP backpressure. */ }
          if (current.closed) break;
          main.post(() -> pump(current));
        }
      } catch (InterruptedException ignored) {
        Thread.currentThread().interrupt();
      } catch (IOException ignored) {
      } finally { main.post(() -> { if (isCurrent(current)) closeLink(current, "local_stream_closed"); }); }
    });
    runIo(current, () -> {
      try {
        OutputStream output = socket.getOutputStream();
        while (!current.closed) {
          byte[] bytes = current.incoming.poll(1, TimeUnit.SECONDS);
          if (bytes == null) continue;
          output.write(bytes);
          int consumed = bytes.length;
          main.post(() -> {
            if (!isCurrent(current)) return;
            current.creditPending += consumed;
            pump(current);
          });
        }
      } catch (InterruptedException ignored) {
        Thread.currentThread().interrupt();
      } catch (IOException ignored) {
      } finally { main.post(() -> { if (isCurrent(current)) closeLink(current, "local_stream_closed"); }); }
    });
  }

  private void runIo(Link current, Runnable task) {
    try { if (io != null) io.execute(task); else closeLink(current, "stopped"); }
    catch (RejectedExecutionException error) { closeLink(current, "local_io_capacity"); }
  }

  private void armOperation(Link current, String operation) {
    current.operation = operation;
    current.operationDeadline.arm(OP_TIMEOUT_MS, () -> {
      if (isCurrent(current) && current.operation != null) closeLink(current, "gatt_" + operation + "_timeout");
    });
  }
  private void completeOperation(Link current) {
    current.operation = null;
    current.operationDeadline.cancel();
  }
  private void armSetup(Link current) {
    current.setupDeadline.arm(SETUP_TIMEOUT_MS,
        () -> { if (isCurrent(current) && current.socket == null) closeLink(current, "setup_timeout"); });
  }

  private boolean isCurrent(Link current) { return running && current != null && current == link && !current.closed; }
  private boolean matches(Link current, String id) { return isCurrent(current) && current.id.equals(id); }
  private boolean samePeripheral(Link current, BluetoothDevice device) {
    return isCurrent(current) && !current.central && current.device.equals(device);
  }

  private void closeLink(Link current, String reason) {
    if (current == null || current.closed) return;
    current.closed = true;
    current.operationDeadline.cancel();
    current.setupDeadline.cancel();
    current.admissionDeadline.cancel();
    current.sessionDeadline.cancel();
    close(current.socket); close(current.endpoint); close(current.connectingSocket);
    current.incoming.clear(); current.outgoing.clear(); current.hello.clear();
    if (current.gatt != null) {
      try { current.gatt.disconnect(); } catch (RuntimeException ignored) {}
      try { current.gatt.close(); } catch (RuntimeException ignored) {}
    } else if (server != null) try { server.cancelConnection(current.device); } catch (RuntimeException ignored) {}
    if (current != link) return;
    link = null;
    try {
      retryAfter.put(current.device.getAddress(), SystemClock.elapsedRealtime() + 15000 + random.nextInt(5000));
      while (retryAfter.size() > 64) retryAfter.remove(retryAfter.keySet().iterator().next());
    } catch (RuntimeException ignored) {}
    Map<String, Object> event = event("endpointLost", current); event.put("reason", reason); emit(event);
    publishState(running ? "discovering" : "stopped", reason);
    int session = generation;
    main.postDelayed(() -> { if (running && session == generation && link == null) { startScan(); startAdvertising(); } }, 1500 + random.nextInt(1000));
  }

  private void stopInternal() {
    running = false;
    resetRadio();
    if (io != null) io.shutdownNow();
    io = null;
    publishState("stopped", null);
  }

  private void resetRadio() {
    generation++;
    stopScan(); stopAdvertising();
    if (link != null) closeLink(link, "stopped");
    if (server != null) try { server.close(); } catch (RuntimeException ignored) {}
    server = null; serverTx = null; serviceReady = false;
    scanner = null; advertiser = null; adapter = null;
  }

  private Map<String, Object> event(String type, Link current) {
    Map<String, Object> event = new HashMap<>();
    event.put("type", type); event.put("transport", "bluetooth");
    if (current != null) event.put("routeId", current.id);
    return event;
  }
  private void publishState(String value, String detail) {
    Map<String, Object> next = event("status", link);
    next.put("state", value); next.put("running", running);
    next.put("scanning", scanning); next.put("advertising", advertising);
    next.put("peripheralSupported", advertiser != null && server != null);
    next.put("foregroundDiscoveryOnly", Build.VERSION.SDK_INT >= 29 && Build.VERSION.SDK_INT <= 30 &&
        !permitted(Manifest.permission.ACCESS_BACKGROUND_LOCATION));
    next.put("appVisible", appVisible);
    next.put("maxLinks", 1); next.put("receiveWindowBytes", BleWire.WINDOW);
    if (detail != null) next.put("detail", detail);
    if (link != null) next.put("gattPayloadBytes", link.payloadSize);
    state = Collections.unmodifiableMap(next);
    emit(new HashMap<>(next));
  }
  private void emit(Map<String, Object> event) {
    try { listener.onEvent(event); } catch (RuntimeException ignored) { /* UI detach must not break cleanup. */ }
  }
  private static void close(java.io.Closeable closeable) {
    if (closeable != null) try { closeable.close(); } catch (IOException ignored) {}
  }

  private static final class Link {
    final String id = "ble-" + UUID.randomUUID();
    final BluetoothDevice device;
    final boolean central;
    final byte[] localBeacon;
    final BleWire.Decoder decoder = new BleWire.Decoder();
    final BleRuntime.Deadline operationDeadline, setupDeadline, admissionDeadline, sessionDeadline;
    final ArrayDeque<byte[]> hello = new ArrayDeque<>();
    // Outbound <=128*509 bytes. Inbound bytes additionally limited by WINDOW;
    // 512 entries accommodate an honest full window at the minimum 23-byte MTU.
    final ArrayBlockingQueue<byte[]> outgoing = new ArrayBlockingQueue<>(128);
    final ArrayBlockingQueue<byte[]> incoming = new ArrayBlockingQueue<>(512);
    volatile boolean closed;
    volatile Socket connectingSocket;
    volatile ServerSocket endpoint;
    Socket socket;
    BluetoothGatt gatt;
    BluetoothGattCharacteristic rx, tx;
    byte[] remoteBeacon, inFlight;
    int payloadSize = 17, sendSequence, sendCredit, receiveCredit, creditPending;
    long attachedAtMs;
    String operation;
    boolean helloStarted, accepted, remoteReady, readyPending, readySent, endpointPending;
    Link(BluetoothDevice device, boolean central, byte[] localBeacon, BleRuntime.Scheduler deadlines) {
      this.device = device; this.central = central; this.localBeacon = localBeacon.clone();
      operationDeadline = new BleRuntime.Deadline(deadlines);
      setupDeadline = new BleRuntime.Deadline(deadlines);
      admissionDeadline = new BleRuntime.Deadline(deadlines);
      sessionDeadline = new BleRuntime.Deadline(deadlines);
    }
  }
}
