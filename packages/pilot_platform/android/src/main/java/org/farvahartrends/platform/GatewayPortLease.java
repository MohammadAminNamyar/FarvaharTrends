package org.farvahartrends.platform;

import android.content.Context;
import android.net.ConnectivityManager;
import android.net.LinkAddress;
import android.net.LinkProperties;
import android.net.Network;
import android.net.NetworkCapabilities;
import android.net.RouteInfo;
import android.os.Handler;
import android.os.Looper;
import android.os.SystemClock;
import java.net.DatagramPacket;
import java.net.DatagramSocket;
import java.net.Inet4Address;
import java.net.InetAddress;
import java.net.InetSocketAddress;
import java.nio.ByteBuffer;
import java.util.Arrays;
import java.util.HashMap;
import java.util.Map;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

/** Short, automatically renewed TCP lease on the active Wi-Fi gateway only.
 * No scanning, remote UPnP URLs, process network changes or mobile fallback.
 */
final class GatewayPortLease {
  interface Callback { void done(Map<String, Object> value); }
  private final ConnectivityManager connectivity;
  private final Handler main = new Handler(Looper.getMainLooper());
  private final ExecutorService worker = Executors.newSingleThreadExecutor();
  private Network network;
  private InetAddress local, gateway;
  private String publicHost;
  private int internalPort, externalPort;
  private long expires, nextAttempt;
  private long grantedLifetimeMs;
  private boolean closed;

  GatewayPortLease(Context context) {
    connectivity = (ConnectivityManager)context.getSystemService(Context.CONNECTIVITY_SERVICE);
  }

  void refresh(int port, Callback callback) {
    worker.execute(() -> {
      Map<String, Object> result;
      try { result = refreshImpl(port); }
      catch (Exception ignored) { result = state("unavailable"); }
      final Map<String, Object> value = result;
      main.post(() -> callback.done(value));
    });
  }

  void release(Callback callback) {
    worker.execute(() -> {
      releaseImpl();
      main.post(() -> callback.done(state("stopped")));
    });
  }

  void close() {
    worker.execute(() -> { closed = true; releaseImpl(); });
    worker.shutdown();
  }

  private Map<String, Object> refreshImpl(int port) throws Exception {
    if (closed || port < 1 || port > 65535) return state("unavailable");
    final long now = SystemClock.elapsedRealtime();
    Network active = connectivity.getActiveNetwork();
    NetworkCapabilities caps = connectivity.getNetworkCapabilities(active);
    if (active == null || caps == null || !caps.hasTransport(NetworkCapabilities.TRANSPORT_WIFI)
        || caps.hasTransport(NetworkCapabilities.TRANSPORT_VPN)) {
      releaseImpl();
      return state("no_wifi");
    }
    if (network != null && (!network.equals(active) || internalPort != port)) releaseImpl();
    if (externalPort > 0 && expires - now > 60000) return leased(now);
    if (network != null && network.equals(active) && now < nextAttempt) return state("unavailable");
    network = active;
    nextAttempt = now + 60000;
    LinkProperties properties = connectivity.getLinkProperties(active);
    if (properties == null) return state("unavailable");
    local = null; gateway = null;
    for (LinkAddress address : properties.getLinkAddresses()) {
      if (address.getAddress() instanceof Inet4Address) { local = address.getAddress(); break; }
    }
    for (RouteInfo route : properties.getRoutes()) {
      if (route.isDefaultRoute() && route.getGateway() instanceof Inet4Address) { gateway = route.getGateway(); break; }
    }
    if (local == null || gateway == null || !gateway.isSiteLocalAddress()) return state("unavailable");
    byte[] answer = request(new byte[]{0, 0});
    if (answer.length != 12 || answer[0] != 0 || (answer[1] & 255) != 128
        || answer[2] != 0 || answer[3] != 0) return state("unavailable");
    InetAddress address = InetAddress.getByAddress(Arrays.copyOfRange(answer, 8, 12));
    if (!publicV4(address)) return state("unavailable");
    publicHost = address.getHostAddress();
    internalPort = port;
    try {
      externalPort = mapping(port, externalPort > 0 ? externalPort : port, 120);
      expires = SystemClock.elapsedRealtime() + grantedLifetimeMs;
      nextAttempt = 0;
      return leased(SystemClock.elapsedRealtime());
    } catch (Exception error) {
      releaseImpl();
      network = active;
      nextAttempt = now + 60000;
      throw error;
    }
  }

  private Map<String, Object> leased(long now) {
    Map<String, Object> value = state("leased");
    value.put("host", publicHost);
    value.put("port", externalPort);
    value.put("remainingMs", Math.max(0, expires - now));
    value.put("leaseId", publicHost + ":" + externalPort + ":" + expires);
    return value;
  }

  private void releaseImpl() {
    if (externalPort > 0 && network != null && local != null && gateway != null) {
      try { mapping(internalPort, externalPort, 0); } catch (Exception ignored) { /* Lease expires within 120 seconds. */ }
    }
    externalPort = 0; internalPort = 0; expires = 0; publicHost = null;
    network = null; local = null; gateway = null; nextAttempt = 0;
  }

  private byte[] request(byte[] bytes) throws Exception {
    try (DatagramSocket socket = new DatagramSocket(null)) {
      network.bindSocket(socket);
      socket.bind(new InetSocketAddress(local, 0));
      socket.connect(gateway, 5351);
      socket.setSoTimeout(1200);
      socket.send(new DatagramPacket(bytes, bytes.length));
      byte[] answer = new byte[64];
      DatagramPacket packet = new DatagramPacket(answer, answer.length);
      socket.receive(packet);
      return Arrays.copyOf(packet.getData(), packet.getLength());
    }
  }

  private int mapping(int port, int external, int lifetime) throws Exception {
    byte[] bytes = ByteBuffer.allocate(12).put((byte)0).put((byte)2).putShort((short)0)
      .putShort((short)port).putShort((short)external).putInt(lifetime).array();
    byte[] answer = request(bytes);
    if (answer.length != 16) throw new Exception("Invalid lease reply");
    ByteBuffer reply = ByteBuffer.wrap(answer);
    int version = reply.get() & 255, opcode = reply.get() & 255, code = reply.getShort() & 65535;
    reply.getInt();
    int internal = reply.getShort() & 65535, mapped = reply.getShort() & 65535;
    long granted = reply.getInt() & 0xffffffffL;
    if (version != 0 || opcode != 130 || code != 0 || internal != port || (lifetime > 0 && mapped == 0)
        || (lifetime > 0 && (granted < 60 || granted > 120)) || (lifetime == 0 && granted != 0)) {
      if (lifetime > 0 && version == 0 && opcode == 130 && code == 0 && internal == port && mapped > 0) {
        // Reject unexpectedly long router grants and attempt immediate deletion.
        try { mapping(port, mapped, 0); } catch (Exception ignored) { }
      }
      throw new Exception("Gateway rejected a bounded lease");
    }
    if (lifetime > 0) grantedLifetimeMs = granted * 1000;
    return mapped;
  }

  static boolean publicV4(InetAddress address) {
    if (!(address instanceof Inet4Address)) return false;
    byte[] bytes = address.getAddress();
    int a = bytes[0] & 255, b = bytes[1] & 255, c = bytes[2] & 255;
    return !(a == 0 || a == 10 || a == 127 || a >= 224 || (a == 100 && b >= 64 && b <= 127)
      || (a == 169 && b == 254) || (a == 172 && b >= 16 && b <= 31)
      || (a == 192 && (b == 168 || b == 0 || b == 2 || (b == 88 && c == 99)))
      || (a == 198 && (b == 18 || b == 19 || (b == 51 && c == 100)))
      || (a == 203 && b == 0 && c == 113));
  }

  private static Map<String, Object> state(String state) {
    Map<String, Object> value = new HashMap<>(); value.put("state", state); return value;
  }
}
