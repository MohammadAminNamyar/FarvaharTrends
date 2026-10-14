package org.farvahartrends.platform;

import android.content.Context;
import android.net.ConnectivityManager;
import android.net.LinkAddress;
import android.net.LinkProperties;
import android.net.Network;
import android.net.NetworkCapabilities;
import android.net.NetworkRequest;
import android.net.RouteInfo;
import android.os.Handler;
import android.os.Looper;
import android.os.SystemClock;
import android.system.ErrnoException;
import android.util.Log;
import java.io.Closeable;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.net.DatagramPacket;
import java.net.Inet4Address;
import java.net.InetAddress;
import java.net.InetSocketAddress;
import java.net.InterfaceAddress;
import java.net.MulticastSocket;
import java.net.NetworkInterface;
import java.net.ServerSocket;
import java.net.Socket;
import java.net.SocketTimeoutException;
import java.security.SecureRandom;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.Collections;
import java.util.HashMap;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.RejectedExecutionException;

/**
 * The Nearby-only boundary. Only this class creates LAN sockets in that mode.
 * Ordinary Wi-Fi sockets are pinned to an actual non-VPN Android Network;
 * endpoints must be on a connected route on that network, never via its gateway.
 * Wi-Fi Direct remains disabled here because many Android releases expose no
 * bindable Network for its group. It remains available in All networks mode.
 * TLS and publisher signatures remain opaque and are verified by the Dart engine.
 */
final class LocalWifiTransport {
  interface Listener { void onEvent(Map<String, Object> event); }
  private static final int MAX_FLOWS = 8, MAX_DOMAINS = 4, MAX_ADDRESSES = 8;
  private static final long REFRESH_MS = 2000;
  private final ConnectivityManager connectivity;
  private final Listener listener;
  private final Handler main = new Handler(Looper.getMainLooper());
  private final Map<String, Domain> domains = new LinkedHashMap<>();
  private final List<Flow> flows = new ArrayList<>();
  private final Map<String, Long> probeTimes = new LinkedHashMap<>();
  private final Map<String, Long> admissionDiagnosticTimes = new HashMap<>();
  private final LocalWifiIngressBudget ingressBudget = new LocalWifiIngressBudget();
  private final SecureRandom random = new SecureRandom();
  private volatile boolean running;
  private volatile byte[] beacon = new byte[0];
  // Engine-issued secrets for its loopback ingress listeners; see LoopbackPreface.
  private volatile byte[] ingressPreface = new byte[0], wifiDirectIngressPreface = new byte[0];
  private ExecutorService io;
  private int generation, tcpPort, ingressPort, wifiDirectIngressPort, discoveryPort;
  private long lastAnnouncement;
  private long rateStart;
  private int rateCount;
  private boolean registered;
  private String detail;

  LocalWifiTransport(Context context, Listener listener) {
    connectivity = (ConnectivityManager) context.getSystemService(Context.CONNECTIVITY_SERVICE);
    this.listener = listener;
  }

  private final ConnectivityManager.NetworkCallback callback = new ConnectivityManager.NetworkCallback() {
    @Override public void onAvailable(Network network) { refresh(); }
    @Override public void onLost(Network network) { refresh(); }
    @Override public void onCapabilitiesChanged(Network network, NetworkCapabilities caps) { refresh(); }
    @Override public void onLinkPropertiesChanged(Network network, LinkProperties properties) { refresh(); }
  };

  private final Runnable maintenance = new Runnable() {
    @Override public void run() {
      if (!running) return;
      refresh();
      main.postDelayed(this, REFRESH_MS);
    }
  };

  synchronized void start(int tcpPort, int ingressPort, int wifiDirectIngressPort,
      int discoveryPort, byte[] signedBeacon, byte[] ingressPreface,
      byte[] wifiDirectIngressPreface) throws IOException {
    stop();
    if (!validPort(tcpPort) || !validPort(ingressPort) || !validPort(wifiDirectIngressPort)
        || !validPort(discoveryPort) || signedBeacon == null
        || signedBeacon.length == 0 || signedBeacon.length > 4096 || connectivity == null
        || !LoopbackPreface.valid(ingressPreface) || !LoopbackPreface.valid(wifiDirectIngressPreface)) {
      throw new IllegalArgumentException("Invalid local Wi-Fi configuration");
    }
    this.tcpPort = tcpPort;
    this.ingressPort = ingressPort;
    this.wifiDirectIngressPort = wifiDirectIngressPort;
    this.discoveryPort = discoveryPort;
    this.ingressPreface = ingressPreface.clone();
    this.wifiDirectIngressPreface = wifiDirectIngressPreface.clone();
    beacon = signedBeacon.clone();
    running = true;
    generation++;
    // At most 36 interface listeners plus two pumps for each of eight flows.
    // Threads are created lazily; the admission budget bounds queued flow work.
    io = Executors.newFixedThreadPool(64);
    lastAnnouncement = 0;
    detail = null;
    try {
      NetworkRequest request = new NetworkRequest.Builder()
          .addTransportType(NetworkCapabilities.TRANSPORT_WIFI)
          .addCapability(NetworkCapabilities.NET_CAPABILITY_NOT_VPN).build();
      connectivity.registerNetworkCallback(request, callback, main);
      registered = true;
      refresh();
      main.postDelayed(maintenance, REFRESH_MS);
    } catch (RuntimeException error) {
      diagnostic("start", error);
      stop();
      throw error;
    }
  }

  synchronized void updateBeacon(byte[] next) {
    if (next == null || next.length == 0 || next.length > 4096) throw new IllegalArgumentException("Invalid beacon");
    beacon = next.clone();
  }

  synchronized void updateP2p(Map<String, Object> state) {
    // No source-address-only P2P fallback is allowed in Nearby-only mode.
  }

  synchronized boolean isRunning() { return running; }

  /**
   * Returned proxy is single-use, loopback-only, bounded, and expires after 8s.
   * Its per-flow preface travels back only over the platform channel; the
   * Dart dialer writes it before TLS and a wrong local caller cannot steal it.
   */
  synchronized Map<String, Object> openPeer(String host, int port) throws IOException {
    if (!running) {
      admissionDiagnostic("open_stopped");
      throw new IOException("Local Wi-Fi is unavailable");
    }
    if (!validPort(port)) {
      admissionDiagnostic("open_invalid_port");
      throw new IOException("Invalid local Wi-Fi peer port");
    }
    InetAddress remote;
    try { remote = LocalWifiRules.numericAddress(host); }
    catch (IOException error) { admissionDiagnostic("open_invalid_endpoint"); throw error; }
    Domain domain = domainFor(remote);
    if (domain == null) {
      admissionDiagnostic(domains.isEmpty() ? "open_wifi_unavailable" : "open_onlink_unavailable");
      throw new IOException("Peer is not on a current local Wi-Fi link");
    }
    if (!domain.current()) {
      admissionDiagnostic("open_network_changed");
      throw new IOException("Peer is not on a current local Wi-Fi link");
    }
    if (flows.size() >= MAX_FLOWS) {
      admissionDiagnostic("open_flow_capacity");
      throw new IOException("Local Wi-Fi connection limit reached");
    }
    Flow flow;
    try { flow = reserve(domain, false); }
    catch (IOException error) { admissionDiagnostic("open_reserve_unavailable"); throw error; }
    try {
      ServerSocket endpoint = new ServerSocket();
      flow.endpoint = endpoint;
      flow.preface = LoopbackPreface.newToken(random);
      flow.deadlineMs = SystemClock.elapsedRealtime() + 8000;
      endpoint.bind(new InetSocketAddress(InetAddress.getByName("127.0.0.1"), 0), LoopbackPreface.BACKLOG);
      submit(() -> attachOutbound(flow, remote, port));
      Map<String, Object> result = new HashMap<>();
      result.put("host", "127.0.0.1");
      result.put("port", endpoint.getLocalPort());
      result.put("transport", domain.transport);
      result.put("preface", flow.preface.clone());
      return result;
    } catch (IOException | RuntimeException error) {
      closeFlow(flow);
      throw error;
    }
  }

  synchronized void probe(String host, int port) throws IOException {
    if (!running || !validPort(port)) throw new IOException("Local Wi-Fi is unavailable");
    InetAddress remote = LocalWifiRules.numericAddress(host);
    Domain domain = domainFor(remote);
    if (domain == null || !domain.current()) throw new IOException("Discovery destination is off-link");
    long now = SystemClock.elapsedRealtime();
    String key = domain.key + ":" + host + ":" + port;
    Long previous = probeTimes.get(key);
    if (previous != null && now - previous < 10000) return;
    if (probeTimes.size() >= 64 && previous == null) probeTimes.remove(probeTimes.keySet().iterator().next());
    probeTimes.put(key, now);
    queueSend(domain, remote, port);
  }

  synchronized Map<String, Object> snapshot() {
    Map<String, Object> state = new HashMap<>();
    state.put("type", "localWifiState");
    state.put("transport", "localWifi");
    state.put("running", running);
    state.put("generation", generation);
    boolean wifi = false, p2p = false;
    List<Map<String, Object>> addresses = new ArrayList<>();
    for (Domain domain : domains.values()) {
      wifi |= domain.network != null;
      p2p |= domain.network == null;
      for (Address address : domain.addresses) {
        Map<String, Object> entry = new HashMap<>();
        entry.put("host", address.local.getHostAddress());
        entry.put("prefixLength", address.prefix);
        entry.put("interface", domain.interfaceName);
        entry.put("transport", domain.transport);
        addresses.add(entry);
      }
    }
    state.put("wifiAvailable", wifi);
    state.put("wifiDirectAvailable", p2p);
    state.put("wifiDirectSupported", false);
    state.put("addresses", addresses);
    state.put("activeFlows", flows.size());
    if (detail != null) state.put("detail", detail);
    return state;
  }

  synchronized void stop() {
    running = false;
    generation++;
    main.removeCallbacks(maintenance);
    if (registered) {
      try { connectivity.unregisterNetworkCallback(callback); } catch (RuntimeException ignored) {}
      registered = false;
    }
    for (Flow flow : new ArrayList<>(flows)) closeFlow(flow);
    for (Domain domain : domains.values()) domain.close();
    domains.clear();
    probeTimes.clear();
    ingressBudget.reset();
    beacon = new byte[0];
    ingressPreface = new byte[0];
    wifiDirectIngressPreface = new byte[0];
    if (io != null) io.shutdownNow();
    io = null;
    emit(snapshot());
  }

  private synchronized void refresh() {
    if (!running) return;
    Map<String, Domain> available = new LinkedHashMap<>();
    try {
      for (Network network : connectivity.getAllNetworks()) {
        if (available.size() >= MAX_DOMAINS) break;
        NetworkCapabilities caps = connectivity.getNetworkCapabilities(network);
        if (caps == null || !caps.hasTransport(NetworkCapabilities.TRANSPORT_WIFI)
            || caps.hasTransport(NetworkCapabilities.TRANSPORT_VPN)
            || !caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_NOT_VPN)) continue;
        LinkProperties properties = connectivity.getLinkProperties(network);
        Domain domain = wifiDomain(network, properties);
        if (domain != null) available.put(domain.key, domain);
      }
    } catch (Exception error) {
      diagnostic("refresh", error);
      detail = "local_wifi_state_unavailable";
    }
    boolean changed = !available.keySet().equals(domains.keySet());
    for (String key : new ArrayList<>(domains.keySet())) {
      if (available.containsKey(key)) continue;
      Domain old = domains.remove(key);
      old.close();
      for (Flow flow : new ArrayList<>(flows)) if (flow.domain == old) closeFlow(flow);
    }
    for (Domain domain : available.values()) {
      if (domains.containsKey(domain.key)) continue;
      domains.put(domain.key, domain);
      startDomain(domain);
    }
    for (Domain domain : domains.values()) if (domain.udp == null) startDiscovery(domain);
    if (changed) { generation++; emit(snapshot()); }
    long now = SystemClock.elapsedRealtime();
    if (now - lastAnnouncement >= 10000 || lastAnnouncement == 0) {
      lastAnnouncement = now;
      for (Domain domain : domains.values()) {
        if (domain.udp != null) {
          try { queueSend(domain, InetAddress.getByName("239.255.71.71"), discoveryPort); }
          catch (IOException ignored) { detail = "local_wifi_announce_unavailable"; }
        }
      }
    }
  }

  private Domain wifiDomain(Network network, LinkProperties properties) throws IOException {
    if (properties == null || properties.getInterfaceName() == null) return null;
    String name = properties.getInterfaceName();
    NetworkInterface iface = NetworkInterface.getByName(name);
    if (iface == null || !iface.isUp() || iface.isLoopback()) return null;
    List<Address> addresses = new ArrayList<>();
    for (LinkAddress link : properties.getLinkAddresses()) {
      if (addresses.size() >= MAX_ADDRESSES) break;
      if (!LocalWifiRules.validLocal(link.getAddress(), link.getPrefixLength())) continue;
      boolean connected = false;
      for (RouteInfo route : properties.getRoutes()) {
        if (!route.hasGateway() && name.equals(route.getInterface())
            && route.getDestination().getPrefixLength() > 0
            && route.getDestination().contains(link.getAddress())) { connected = true; break; }
      }
      if (connected) addresses.add(new Address(link.getAddress(), link.getPrefixLength()));
    }
    if (addresses.isEmpty()) return null;
    List<String> routes = new ArrayList<>();
    for (RouteInfo route : properties.getRoutes()) routes.add(route.toString());
    Collections.sort(routes);
    // Changes to more-specific/gateway routes invalidate live flows too, even
    // when Android keeps the same Network handle and interface address.
    return new Domain("wifi:" + network.getNetworkHandle() + ":" + routes, name, network, "lan", addresses);
  }

  private synchronized void startDomain(Domain domain) {
    try {
      for (Address address : domain.addresses) {
        ServerSocket server = new NetworkBoundServer(domain.network, address.local, tcpPort);
        domain.servers.add(server);
        submit(() -> accept(domain, server, address));
      }
    } catch (Exception error) {
      diagnostic("listener", error);
      domain.close();
      domains.remove(domain.key);
      detail = "local_wifi_bind_unavailable";
      emit(snapshot());
      return;
    }
    startDiscovery(domain);
  }

  private synchronized void startDiscovery(Domain domain) {
    if (!domain.current() || domain.udp != null) return;
    try {
      Address ipv4 = domain.addresses.stream().filter(a -> a.local instanceof Inet4Address).findFirst().orElse(null);
      if (ipv4 != null) {
        MulticastSocket udp = new MulticastSocket(null);
        domain.udp = udp;
        udp.setReuseAddress(true);
        if (domain.network != null) domain.network.bindSocket(udp);
        udp.bind(new InetSocketAddress(discoveryPort));
        udp.setTimeToLive(1);
        udp.setNetworkInterface(NetworkInterface.getByName(domain.interfaceName));
        udp.joinGroup(new InetSocketAddress("239.255.71.71", discoveryPort),
            NetworkInterface.getByName(domain.interfaceName));
        submit(() -> receive(domain, udp));
      }
    } catch (Exception error) {
      diagnostic("discovery", error);
      close(domain.udp);
      domain.udp = null;
      detail = "local_wifi_discovery_unavailable";
      emit(snapshot());
    }
  }

  private void accept(Domain domain, ServerSocket server, Address address) {
    while (running && !domain.closed) {
      Socket remote = null;
      Flow flow = null;
      try {
        remote = server.accept();
        synchronized (this) {
          if (!domain.current() || !address.local.equals(remote.getLocalAddress())
              || !domain.allows(remote.getInetAddress())) { close(remote); continue; }
          int incoming = 0;
          for (Flow current : flows) if (current.incoming) incoming++;
          // Enforce real source quotas before its address is hidden by the
          // loopback proxy, leaving half the capacity for outbound connections.
          if (!ingressBudget.allow(remote.getInetAddress().getHostAddress(),
              SystemClock.elapsedRealtime(), incoming, flows.size())) {
            close(remote); continue;
          }
          flow = reserve(domain, true);
          flow.remote = remote;
        }
        Flow acceptedFlow = flow;
        submit(() -> attachInbound(acceptedFlow));
      } catch (IOException | RuntimeException error) {
        close(remote);
        if (flow != null) closeFlow(flow);
        if (server.isClosed() || domain.closed || !running) return;
      }
    }
  }

  private void attachInbound(Flow flow) {
    try {
      Socket local = new Socket();
      synchronized (this) {
        if (!flow.current()) { close(local); closeFlow(flow); return; }
        flow.local = local;
      }
      boolean direct = flow.domain.network == null;
      local.connect(new InetSocketAddress("127.0.0.1", direct ? wifiDirectIngressPort : ingressPort), 5000);
      // Prove in-process origin to the engine's loopback ingress before TLS.
      LoopbackPreface.write(local, direct ? wifiDirectIngressPreface : ingressPreface);
      pump(flow);
    } catch (IOException | RuntimeException error) { closeFlow(flow); }
  }

  private void attachOutbound(Flow flow, InetAddress remoteAddress, int port) {
    try {
      // Keeps listening after a wrong local caller until the 8s flow deadline;
      // closes the listener once a caller proves the per-flow preface.
      Socket local = LoopbackPreface.accept(flow.endpoint, flow.preface, flow.deadlineMs,
          SystemClock::elapsedRealtime);
      synchronized (this) {
        if (!flow.current() || !local.getInetAddress().isLoopbackAddress()) { close(local); closeFlow(flow); return; }
        flow.local = local;
      }
      Socket remote = new Socket();
      Address source;
      synchronized (this) {
        if (!flow.current()) { close(remote); closeFlow(flow); return; }
        flow.remote = remote;
        if (!flow.domain.allows(remoteAddress)) throw new IOException("Local route changed");
        source = flow.domain.sourceFor(remoteAddress);
        if (source == null) throw new IOException("Local route changed");
      }
      // Both mark the real Wi-Fi Network and pin its actual source address.
      // bindSocket must run before connect; Android never substitutes cellular.
      if (flow.domain.network != null) flow.domain.network.bindSocket(remote);
      remote.bind(new InetSocketAddress(source.local, 0));
      remote.connect(new InetSocketAddress(remoteAddress, port), 6000);
      synchronized (this) {
        if (!flow.current() || !flow.domain.allows(remoteAddress) || !source.local.equals(remote.getLocalAddress())) {
          throw new IOException("Local Wi-Fi route changed during connect");
        }
      }
      pump(flow);
    } catch (IOException | RuntimeException error) { closeFlow(flow); }
  }

  private void pump(Flow flow) throws IOException {
    synchronized (this) {
      if (!flow.current()) throw new IOException("Local route is no longer available");
      flow.local.setTcpNoDelay(true);
      flow.remote.setTcpNoDelay(true);
      flow.local.setSoTimeout(120000);
      flow.remote.setSoTimeout(120000);
    }
    submit(() -> copy(flow, flow.local, flow.remote));
    copy(flow, flow.remote, flow.local);
  }

  private void copy(Flow flow, Socket source, Socket destination) {
    try {
      byte[] buffer = new byte[8192];
      InputStream input = source.getInputStream();
      OutputStream output = destination.getOutputStream();
      int count;
      while (flow.current() && (count = input.read(buffer)) != -1) output.write(buffer, 0, count);
    } catch (IOException ignored) { /* Closing either half always tears down both sockets. */ }
    finally { closeFlow(flow); }
  }

  private void receive(Domain domain, MulticastSocket udp) {
    byte[] buffer = new byte[4097];
    while (running && !domain.closed) {
      try {
        DatagramPacket packet = new DatagramPacket(buffer, buffer.length);
        udp.receive(packet);
        Map<String, Object> event;
        synchronized (this) {
          if (!domain.current() || !domain.allows(packet.getAddress())
              || packet.getLength() == 0 || packet.getLength() > 4096) continue;
          long now = SystemClock.elapsedRealtime();
          if (now - rateStart >= 10000) { rateStart = now; rateCount = 0; }
          if (++rateCount > 32) continue;
          event = new HashMap<>();
          event.put("type", "localWifiBeacon");
          event.put("transport", domain.transport);
          event.put("host", packet.getAddress().getHostAddress());
          event.put("signedBeacon", Arrays.copyOfRange(packet.getData(), packet.getOffset(), packet.getOffset() + packet.getLength()));
        }
        main.post(() -> {
          synchronized (LocalWifiTransport.this) {
            if (domain.current()) listener.onEvent(event);
          }
        });
      } catch (IOException | RuntimeException error) {
        if (udp.isClosed() || domain.closed || !running) return;
      }
    }
  }

  private synchronized void send(Domain domain, InetAddress remote, int port) throws IOException {
    if (!domain.current()) throw new IOException("Local Wi-Fi route changed");
    if (!remote.isMulticastAddress() && !domain.allows(remote)) throw new IOException("Off-link destination");
    if (domain.udp == null) throw new IOException("Local Wi-Fi discovery unavailable");
    byte[] bytes = beacon;
    if (bytes.length == 0) return;
    domain.udp.send(new DatagramPacket(bytes, bytes.length, remote, port));
  }

  private void queueSend(Domain domain, InetAddress remote, int port) {
    // Method calls and connectivity callbacks run on Android's main thread.
    // Keep every actual send on the bounded I/O pool; never relax StrictMode.
    submit(() -> {
      try { send(domain, remote, port); }
      catch (IOException | RuntimeException error) {
        synchronized (LocalWifiTransport.this) {
          if (domain.current()) {
            diagnostic("send", error);
            detail = "local_wifi_announce_unavailable";
          }
        }
      }
    });
  }

  private synchronized Domain domainFor(InetAddress remote) {
    for (Domain domain : domains.values()) if (domain.allows(remote)) return domain;
    return null;
  }

  private synchronized Flow reserve(Domain domain, boolean incoming) throws IOException {
    if (!domain.current() || flows.size() >= MAX_FLOWS) throw new IOException("Local Wi-Fi connection limit reached");
    Flow flow = new Flow(domain, incoming);
    flows.add(flow);
    return flow;
  }

  private synchronized void closeFlow(Flow flow) {
    if (flow.closed) return;
    flow.closed = true;
    close(flow.endpoint);
    close(flow.local);
    close(flow.remote);
    flows.remove(flow);
  }

  private void submit(Runnable task) {
    ExecutorService executor = io;
    if (executor == null || executor.isShutdown()) throw new RejectedExecutionException("Local Wi-Fi stopped");
    executor.submit(task);
  }

  private void emit(Map<String, Object> event) {
    main.post(() -> {
      try { listener.onEvent(event); } catch (RuntimeException ignored) {}
    });
  }

  private static boolean validPort(int value) { return value > 0 && value <= 65535; }
  private synchronized void admissionDiagnostic(String category) {
    long now = SystemClock.elapsedRealtime();
    Long previous = admissionDiagnosticTimes.get(category);
    if (previous != null && now - previous < 60000) return;
    // Categories are fixed call-site constants, never peer-controlled strings.
    admissionDiagnosticTimes.put(category, now);
    Log.w("FarvaharTrendsLocalWifi", category);
  }
  private static void diagnostic(String category, Throwable error) {
    String value = category + ":" + error.getClass().getSimpleName();
    Throwable cause = error.getCause();
    if (cause != null) value += ":" + cause.getClass().getSimpleName();
    Throwable errno = error instanceof ErrnoException ? error : cause;
    if (errno instanceof ErrnoException) value += ":errno=" + ((ErrnoException) errno).errno;
    // Never log endpoint addresses, certificates, messages, or exception text.
    Log.w("FarvaharTrendsLocalWifi", value);
  }
  private static void close(Closeable value) {
    if (value != null) try { value.close(); } catch (IOException ignored) {}
  }

  private static final class Address {
    final InetAddress local;
    final int prefix;
    Address(InetAddress local, int prefix) { this.local = local; this.prefix = prefix; }
    @Override public String toString() { return local.getHostAddress() + "/" + prefix; }
  }

  private final class Domain {
    final String key, interfaceName, transport;
    final Network network;
    final List<Address> addresses;
    final List<ServerSocket> servers = new ArrayList<>();
    volatile boolean closed;
    MulticastSocket udp;
    Domain(String networkKey, String interfaceName, Network network, String transport, List<Address> addresses) {
      this.interfaceName = interfaceName;
      this.network = network;
      this.transport = transport;
      this.addresses = addresses;
      key = networkKey + ":" + interfaceName + ":" + addresses;
    }
    boolean allows(InetAddress remote) {
      if (sourceFor(remote) == null || network == null) return false;
      LinkProperties properties = connectivity.getLinkProperties(network);
      if (properties == null) return false;
      int longestPrefix = -1;
      boolean direct = false;
      for (RouteInfo route : properties.getRoutes()) {
        if (!route.getDestination().contains(remote)) continue;
        int prefix = route.getDestination().getPrefixLength();
        if (prefix < longestPrefix) continue;
        boolean candidate = prefix > 0 && !route.hasGateway()
            && route.getType() == RouteInfo.RTN_UNICAST && interfaceName.equals(route.getInterface());
        // Equal-length contradictory routes fail closed too.
        direct = prefix == longestPrefix ? direct && candidate : candidate;
        longestPrefix = prefix;
      }
      return direct;
    }
    Address sourceFor(InetAddress remote) {
      for (Address address : addresses) if (LocalWifiRules.onLink(address.local, address.prefix, remote)) return address;
      return null;
    }
    boolean current() {
      synchronized (LocalWifiTransport.this) {
        if (!running || closed || domains.get(key) != this) return false;
        try {
          NetworkInterface iface = NetworkInterface.getByName(interfaceName);
          if (iface == null || !iface.isUp() || iface.isLoopback()) return false;
          if (network != null) {
            NetworkCapabilities caps = connectivity.getNetworkCapabilities(network);
            if (caps == null || !caps.hasTransport(NetworkCapabilities.TRANSPORT_WIFI)
                || caps.hasTransport(NetworkCapabilities.TRANSPORT_VPN)
                || !caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_NOT_VPN)) return false;
            Domain current = wifiDomain(network, connectivity.getLinkProperties(network));
            return current != null && key.equals(current.key);
          }
          return false;
        } catch (IOException | RuntimeException ignored) { return false; }
      }
    }
    void close() {
      closed = true;
      for (ServerSocket server : servers) LocalWifiTransport.close(server);
      servers.clear();
      LocalWifiTransport.close(udp);
      udp = null;
    }
  }

  private final class Flow {
    final Domain domain;
    final boolean incoming;
    volatile boolean closed;
    ServerSocket endpoint;
    Socket local, remote;
    byte[] preface;
    long deadlineMs;
    Flow(Domain domain, boolean incoming) { this.domain = domain; this.incoming = incoming; }
    boolean current() { return !closed && domain.current(); }
  }
}
