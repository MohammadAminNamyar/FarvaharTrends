package org.farvahartrends.platform;

import android.Manifest;
import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.content.IntentFilter;
import android.content.pm.PackageManager;
import android.location.LocationManager;
import android.net.wifi.WifiManager;
import android.net.wifi.WpsInfo;
import android.net.wifi.p2p.WifiP2pConfig;
import android.net.wifi.p2p.WifiP2pDevice;
import android.net.wifi.p2p.WifiP2pGroup;
import android.net.wifi.p2p.WifiP2pInfo;
import android.net.wifi.p2p.WifiP2pManager;
import android.net.wifi.p2p.nsd.WifiP2pDnsSdServiceInfo;
import android.net.wifi.p2p.nsd.WifiP2pDnsSdServiceRequest;
import android.os.Build;
import android.os.Handler;
import android.os.Looper;
import android.os.SystemClock;
import android.provider.Settings;
import java.net.InetAddress;
import java.net.InterfaceAddress;
import java.net.NetworkInterface;
import java.net.SocketException;
import java.util.ArrayList;
import java.util.Collections;
import java.util.HashMap;
import java.util.Iterator;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.regex.Pattern;

/**
 * Discovers this app's DNS-SD service and asks Android to form a Wi-Fi Direct group.
 *
 * DNS-SD records and the group owner's IP are only route hints. The Dart engine
 * must exchange signed discovery beacons and pin the resulting certificate before
 * using TLS. This class neither admits publishers nor validates human identity.
 * It never enables a radio, requests permissions, bypasses Android's connection
 * prompts, or removes a group belonging to another app. Call only on the main thread.
 */
public final class WiFiDirectTransport {
  public interface Listener {
    void onState(Map<String, Object> state);
  }

  static final String INSTANCE = "farvahartrends";
  static final String SERVICE_TYPE = "_farvahartrends._tcp";
  private static final int MAX_CANDIDATES = 16;
  private static final long CANDIDATE_LIFETIME_MS = 90000L;
  private static final long REFRESH_MS = 30000L;
  private static final long CONNECT_TIMEOUT_MS = 45000L;
  private static final long GROUP_QUERY_TIMEOUT_MS = 15000L;
  // Beacon v2: the TXT record carries a rotating 16-byte session token, never
  // the certificate fingerprint. It is a service hint and tie-breaker only.
  private static final Pattern SESSION_PATTERN = Pattern.compile("[0-9a-f]{32}");
  private static final Pattern MAC_PATTERN = Pattern.compile("(?:[0-9a-f]{2}:){5}[0-9a-f]{2}");

  private final Context context;
  private final Listener listener;
  private final Handler handler = new Handler(Looper.getMainLooper());
  private final Map<String, Candidate> candidates = new LinkedHashMap<>();
  private final AttemptBudget attemptBudget = new AttemptBudget();
  private final GroupOwnership groupOwnership = new GroupOwnership();
  private WifiP2pManager manager;
  private WifiP2pManager.Channel channel;
  private WifiP2pDnsSdServiceInfo localService;
  private WifiP2pDnsSdServiceRequest serviceRequest;
  private boolean receiverRegistered;
  private boolean active;
  private boolean autoConnectAllowed;
  private int generation;
  private int registrationSerial, groupSerial;
  private String sessionToken = "";
  private int tcpPort;
  private String state = "stopped";
  private String lastError;
  private boolean supported;
  private boolean permissionGranted;
  private boolean locationEnabled;
  private boolean enabled;
  private boolean localRegistered;
  private boolean requestRegistered;
  private boolean localRegistering;
  private boolean requestRegistering;
  private boolean discoveryRunning;
  private long lastDiscoveryAt = -REFRESH_MS;
  private long nextRegistrationAt;
  private boolean groupKnown;
  private boolean groupQueryPending;
  private int groupQuerySerial;
  private long groupQueryStartedAt;
  private long groupCheckedAt;
  private boolean groupFormed;
  private boolean isGroupOwner;
  private boolean appGroup;
  private String groupOwnerHost = "";
  private String groupInterface = "";
  private String groupKey = "";
  private List<Map<String, Object>> localAddresses = new ArrayList<>();
  private boolean connecting;
  private long connectStartedAt;
  private String connectingAddress = "";

  private final BroadcastReceiver receiver = new BroadcastReceiver() {
    @Override public void onReceive(Context ignored, Intent intent) {
      if (!active || intent == null) return;
      String action = intent.getAction();
      if (WifiP2pManager.WIFI_P2P_STATE_CHANGED_ACTION.equals(action)) {
        enabled = intent.getIntExtra(WifiP2pManager.EXTRA_WIFI_STATE,
            WifiP2pManager.WIFI_P2P_STATE_DISABLED) == WifiP2pManager.WIFI_P2P_STATE_ENABLED;
        if (!enabled) {
          releaseChannel(false);
        }
      } else if (WifiP2pManager.WIFI_P2P_DISCOVERY_CHANGED_ACTION.equals(action)) {
        discoveryRunning = intent.getIntExtra(WifiP2pManager.EXTRA_DISCOVERY_STATE,
            WifiP2pManager.WIFI_P2P_DISCOVERY_STOPPED) == WifiP2pManager.WIFI_P2P_DISCOVERY_STARTED;
        if (!discoveryRunning && "searching".equals(state)) state = "waiting";
        emit();
        return;
      }
      // Query framework state again: connection broadcasts are not sticky, and
      // broadcast extras alone are never an authenticated peer admission.
      refresh();
    }
  };

  private final Runnable refreshTask = new Runnable() {
    @Override public void run() {
      if (!active) return;
      refresh();
      handler.postDelayed(this, REFRESH_MS);
    }
  };

  public WiFiDirectTransport(Context context, Listener listener) {
    if (context == null || listener == null) throw new IllegalArgumentException("Context and listener required");
    this.context = context.getApplicationContext();
    this.listener = listener;
    updateConditions();
  }

  /** {@code sessionToken} is the engine's rotating discovery session token (32 hex). */
  public void start(String sessionToken, int tcpPort) {
    requireMainThread();
    if (sessionToken == null || !SESSION_PATTERN.matcher(sessionToken).matches()
        || tcpPort < 1 || tcpPort > 65535) {
      throw new IllegalArgumentException("A discovery session token and valid TCP port are required");
    }
    if (active && this.sessionToken.equals(sessionToken) && this.tcpPort == tcpPort) {
      refresh();
      return;
    }
    stopInternal(false);
    this.sessionToken = sessionToken;
    this.tcpPort = tcpPort;
    active = true;
    generation++;
    lastError = null;
    nextRegistrationAt = 0;
    lastDiscoveryAt = -REFRESH_MS;
    attemptBudget.clear();
    registerReceiver();
    if (!receiverRegistered) {
      active = false;
      setState("error");
      return;
    }
    refresh();
    handler.postDelayed(refreshTask, REFRESH_MS);
  }

  public void stop() {
    requireMainThread();
    stopInternal(true);
  }

  /**
   * Allows the controller to prefer an existing Internet/LAN route. Discovery
   * remains available while initiation is paused; Android still controls any
   * incoming connection confirmation. Set after start; a new activation is paused.
   */
  public void setAutoConnectAllowed(boolean allowed) {
    requireMainThread();
    autoConnectAllowed = allowed;
    if (!active) { emit(); return; }
    if (!allowed && connecting) {
      cancelOwnConnect();
      groupKnown = false;
      queryGroup();
    }
    if (allowed) maybeConnect();
    emit();
  }

  public void refresh() {
    requireMainThread();
    if (!active) return;
    updateConditions();
    pruneCandidates(SystemClock.elapsedRealtime());
    if (!supported) { setState("unsupported"); return; }
    if (!permissionGranted) {
      releaseChannel(true);
      setState("permissionRequired");
      return;
    }
    // Android 13+ neverForLocation uses Nearby Wi-Fi permission. Older versions
    // require Location Mode for discovery; do not impose that legacy gate on 33+.
    if (usesLegacyLocationPermission() && !locationEnabled) {
      releaseChannel(false);
      setState("locationRequired");
      return;
    }
    if (channel == null && !openChannel()) return;
    requestEnabledState();
    if (!enabled) { setState("wifiDisabled"); return; }
    long now = SystemClock.elapsedRealtime();
    if (connecting && now - connectStartedAt >= CONNECT_TIMEOUT_MS) {
      cancelOwnConnect();
      lastError = "connect_timeout";
      groupKnown = false;
    }
    if (groupQueryPending && now - groupQueryStartedAt >= GROUP_QUERY_TIMEOUT_MS) {
      groupQueryPending = false;
      groupQuerySerial++;
      groupKnown = false;
      lastError = "group_state_timeout";
    }
    queryGroup();
    advance();
  }

  public Map<String, Object> snapshot() {
    requireMainThread();
    Map<String, Object> result = new HashMap<>();
    result.put("state", state);
    result.put("active", active);
    result.put("autoConnectAllowed", autoConnectAllowed);
    result.put("supported", supported);
    result.put("enabled", enabled);
    result.put("permissionGranted", permissionGranted);
    result.put("locationEnabled", locationEnabled);
    result.put("locationRequired", usesLegacyLocationPermission());
    result.put("serviceCount", validServiceCount());
    result.put("discoveryRunning", discoveryRunning);
    result.put("groupFormed", groupFormed);
    result.put("appGroup", appGroup);
    result.put("locallyRequestedGroup", groupOwnership.mayRemove(groupKey));
    result.put("isGroupOwner", isGroupOwner);
    result.put("groupOwnerHost", appGroup ? groupOwnerHost : "");
    result.put("groupInterface", appGroup ? groupInterface : "");
    result.put("routeId", appGroup && !groupInterface.isEmpty()
        ? "wifiDirect:" + generation + ":" + groupSerial + ":" + groupInterface : "");
    List<Map<String, Object>> addresses = new ArrayList<>();
    if (appGroup) for (Map<String, Object> address : localAddresses) addresses.add(new HashMap<>(address));
    result.put("localAddresses", addresses);
    result.put("autoConnectRemaining", attemptBudget.remaining());
    result.put("lastError", lastError);
    return result;
  }

  private void registerReceiver() {
    IntentFilter filter = new IntentFilter();
    filter.addAction(WifiP2pManager.WIFI_P2P_STATE_CHANGED_ACTION);
    filter.addAction(WifiP2pManager.WIFI_P2P_CONNECTION_CHANGED_ACTION);
    filter.addAction(WifiP2pManager.WIFI_P2P_THIS_DEVICE_CHANGED_ACTION);
    filter.addAction(WifiP2pManager.WIFI_P2P_DISCOVERY_CHANGED_ACTION);
    filter.addAction(WifiManager.WIFI_STATE_CHANGED_ACTION);
    filter.addAction(LocationManager.MODE_CHANGED_ACTION);
    try {
      if (Build.VERSION.SDK_INT >= 33) context.registerReceiver(receiver, filter, Context.RECEIVER_NOT_EXPORTED);
      else context.registerReceiver(receiver, filter);
      receiverRegistered = true;
    } catch (RuntimeException error) {
      lastError = diagnostic("receiver", error);
      state = "error";
    }
  }

  private void updateConditions() {
    supported = context.getPackageManager().hasSystemFeature(PackageManager.FEATURE_WIFI_DIRECT);
    String permission = usesLegacyLocationPermission()
        ? Manifest.permission.ACCESS_FINE_LOCATION : Manifest.permission.NEARBY_WIFI_DEVICES;
    permissionGranted = context.checkSelfPermission(permission) == PackageManager.PERMISSION_GRANTED;
    try {
      LocationManager location = (LocationManager) context.getSystemService(Context.LOCATION_SERVICE);
      locationEnabled = Build.VERSION.SDK_INT >= 28
          ? location != null && location.isLocationEnabled()
          : Settings.Secure.getInt(context.getContentResolver(), Settings.Secure.LOCATION_MODE,
              Settings.Secure.LOCATION_MODE_OFF) != Settings.Secure.LOCATION_MODE_OFF;
    } catch (RuntimeException ignored) { locationEnabled = false; }
    if (channel == null) {
      try {
        WifiManager wifi = (WifiManager) context.getSystemService(Context.WIFI_SERVICE);
        enabled = wifi != null && wifi.isWifiEnabled();
      } catch (RuntimeException ignored) { enabled = false; }
    }
  }

  private boolean usesLegacyLocationPermission() {
    return Build.VERSION.SDK_INT < 33 || context.getApplicationInfo().targetSdkVersion < 33;
  }

  private boolean openChannel() {
    // Every framework channel gets its own callback epoch. A delayed reply from
    // a closed channel must never mutate a newly initialized channel's state.
    final int token = ++generation;
    try {
      manager = (WifiP2pManager) context.getSystemService(Context.WIFI_P2P_SERVICE);
      if (manager == null) { supported = false; setState("unsupported"); return false; }
      channel = manager.initialize(context, Looper.getMainLooper(), () -> {
        if (!current(token)) return;
        // Reinitialization is delayed until the next refresh, preventing an
        // unavailable framework service from creating an immediate retry loop.
        releaseChannel(false);
        lastError = "channel_disconnected";
        setState("error");
      });
      if (channel == null) { lastError = "channel_unavailable"; setState("error"); return false; }
      manager.setDnsSdResponseListeners(channel,
          (instance, type, device) -> {
            if (!current(token) || !isAppService(instance, type)) return;
            Candidate candidate = candidateFor(device);
            if (candidate == null) return;
            candidate.serviceSeenAt = SystemClock.elapsedRealtime();
            serviceObserved();
          },
          (domain, records, device) -> {
            if (!current(token) || !isAppDomain(domain)) return;
            String session = validSession(records);
            int port = validPort(records);
            if (session == null || session.equals(this.sessionToken) || port == 0) return;
            Candidate candidate = candidateFor(device);
            if (candidate == null) return;
            candidate.session = session;
            candidate.port = port;
            candidate.txtSeenAt = SystemClock.elapsedRealtime();
            serviceObserved();
          });
      Map<String, String> txt = new HashMap<>();
      txt.put("app", "farvahartrends");
      txt.put("v", "2");
      txt.put("sid", sessionToken);
      txt.put("port", Integer.toString(tcpPort));
      localService = WifiP2pDnsSdServiceInfo.newInstance(INSTANCE, SERVICE_TYPE, txt);
      // The Android service-discovery API's generic DNS-SD request provides both
      // PTR and TXT callbacks. Both must match before any device can be connected.
      serviceRequest = WifiP2pDnsSdServiceRequest.newInstance();
      groupKnown = false;
      return true;
    } catch (RuntimeException error) {
      releaseChannel(false);
      lastError = diagnostic("initialize", error);
      setState(error instanceof SecurityException ? "permissionRequired" : "error");
      return false;
    }
  }

  private void requestEnabledState() {
    if (Build.VERSION.SDK_INT < 29 || channel == null) return;
    final int token = generation;
    try {
      manager.requestP2pState(channel, value -> {
        if (!current(token)) return;
        boolean wasEnabled = enabled;
        enabled = value == WifiP2pManager.WIFI_P2P_STATE_ENABLED;
        if (!enabled) {
          releaseChannel(false);
          setState("wifiDisabled");
        } else if (!wasEnabled) {
          queryGroup();
          advance();
        }
      });
    } catch (RuntimeException error) { failure("p2p_state", error); }
  }

  private void queryGroup() {
    if (channel == null || groupQueryPending || !enabled || !permissionGranted) return;
    final int token = generation;
    final int serial = ++groupQuerySerial;
    final GroupQuery query = new GroupQuery();
    groupQueryPending = true;
    groupQueryStartedAt = SystemClock.elapsedRealtime();
    try {
      manager.requestConnectionInfo(channel, info -> {
        if (!current(token) || serial != groupQuerySerial) return;
        query.info = info;
        query.infoReceived = true;
        completeGroupQuery(query);
      });
      manager.requestGroupInfo(channel, group -> {
        if (!current(token) || serial != groupQuerySerial) return;
        query.group = group;
        query.groupReceived = true;
        completeGroupQuery(query);
      });
    } catch (RuntimeException error) {
      groupQueryPending = false;
      groupQuerySerial++;
      groupKnown = false;
      failure("group_state", error);
    }
  }

  private void completeGroupQuery(GroupQuery query) {
    if (!query.infoReceived || !query.groupReceived) return;
    groupQueryPending = false;
    groupKnown = true;
    groupCheckedAt = SystemClock.elapsedRealtime();
    WifiP2pInfo info = query.info;
    WifiP2pGroup group = query.group;
    boolean formed = group != null || (info != null && info.groupFormed);
    if (!formed) {
      resetGroupDetails();
    } else {
      String newInterface = group == null || group.getInterface() == null ? "" : group.getInterface();
      String owner = group == null || group.getOwner() == null ? "" : safeMac(group.getOwner());
      String newKey = newInterface + ":" + owner + ":" + (group == null ? -1 : group.getNetworkId());
      if (!groupFormed || !groupKey.equals(newKey)) groupSerial++;
      boolean matched = group != null && groupContainsAppPeer(group);
      List<String> members = new ArrayList<>();
      members.add(owner);
      if (group != null) for (WifiP2pDevice member : group.getClientList()) members.add(safeMac(member));
      groupOwnership.observed(newKey, members);
      appGroup = matched || groupOwnership.mayRemove(newKey) || (appGroup && groupKey.equals(newKey));
      groupKey = newKey;
      groupInterface = newInterface;
      groupFormed = true;
      isGroupOwner = info != null && info.isGroupOwner;
      groupOwnerHost = info == null || info.groupOwnerAddress == null ? "" : info.groupOwnerAddress.getHostAddress();
      localAddresses = interfaceAddresses(newInterface);
      if (appGroup) {
        connecting = false;
        connectingAddress = "";
        lastError = null;
      }
    }
    advance();
  }

  private boolean groupContainsAppPeer(WifiP2pGroup group) {
    long now = SystemClock.elapsedRealtime();
    if (matchesCandidate(safeMac(group.getOwner()), now)) return true;
    for (WifiP2pDevice device : group.getClientList()) {
      if (matchesCandidate(safeMac(device), now)) return true;
    }
    return false;
  }

  private boolean matchesCandidate(String address, long now) {
    Candidate candidate = candidates.get(address);
    return candidate != null && candidate.complete(now)
        && !candidate.session.equals(sessionToken);
  }

  private void advance() {
    if (!active || channel == null || !supported || !permissionGranted || !enabled) return;
    if (usesLegacyLocationPermission() && !locationEnabled) return;
    if (!groupKnown) { setState("checking"); return; }
    if (groupFormed) {
      if (!appGroup) removeOwnDiscoveryRecords();
      setState(appGroup ? "connected" : "occupied");
      return;
    }
    if (connecting) { setState("connecting"); return; }
    ensureRegistered();
    if (!localRegistered || !requestRegistered) {
      if (lastError == null) setState("starting");
      else emit();
      return;
    }
    discoverServices();
    maybeConnect();
  }

  private void ensureRegistered() {
    if (SystemClock.elapsedRealtime() < nextRegistrationAt) return;
    final int token = generation;
    final int registration = registrationSerial;
    try {
      if (!localRegistered && !localRegistering) {
        localRegistering = true;
        manager.addLocalService(channel, localService, new WifiP2pManager.ActionListener() {
          @Override public void onSuccess() {
            if (!current(token) || registration != registrationSerial) return;
            localRegistering = false;
            localRegistered = true;
            lastError = null;
            advance();
          }
          @Override public void onFailure(int reason) {
            if (!current(token) || registration != registrationSerial) return;
            localRegistering = false;
            registrationFailure("advertise", reason);
          }
        });
      }
      if (!requestRegistered && !requestRegistering) {
        requestRegistering = true;
        manager.addServiceRequest(channel, serviceRequest, new WifiP2pManager.ActionListener() {
          @Override public void onSuccess() {
            if (!current(token) || registration != registrationSerial) return;
            requestRegistering = false;
            requestRegistered = true;
            lastError = null;
            advance();
          }
          @Override public void onFailure(int reason) {
            if (!current(token) || registration != registrationSerial) return;
            requestRegistering = false;
            registrationFailure("service_request", reason);
          }
        });
      }
    } catch (RuntimeException error) {
      localRegistering = requestRegistering = false;
      nextRegistrationAt = SystemClock.elapsedRealtime() + REFRESH_MS;
      failure("register", error);
    }
  }

  private void discoverServices() {
    long now = SystemClock.elapsedRealtime();
    if (now - lastDiscoveryAt < REFRESH_MS) {
      if (discoveryRunning) setState("searching");
      return;
    }
    lastDiscoveryAt = now;
    final int token = generation;
    try {
      manager.discoverServices(channel, new WifiP2pManager.ActionListener() {
        @Override public void onSuccess() {
          if (!current(token)) return;
          discoveryRunning = true;
          lastError = null;
          if (!groupFormed && !connecting) setState("searching");
        }
        @Override public void onFailure(int reason) {
          if (!current(token)) return;
          discoveryRunning = false;
          lastError = "discover_" + reasonName(reason);
          if (reason == WifiP2pManager.NO_SERVICE_REQUESTS) requestRegistered = false;
          setState(stateForReason(reason));
        }
      });
    } catch (RuntimeException error) { failure("discover", error); }
  }

  private void serviceObserved() {
    pruneCandidates(SystemClock.elapsedRealtime());
    emit();
    maybeConnect();
  }

  private void maybeConnect() {
    if (!active || !autoConnectAllowed || channel == null || !permissionGranted || !enabled || !groupKnown
        || groupQueryPending || groupFormed || connecting || !localRegistered || !requestRegistered) return;
    if (usesLegacyLocationPermission() && !locationEnabled) return;
    long now = SystemClock.elapsedRealtime();
    Candidate selected = null;
    for (Candidate candidate : candidates.values()) {
      // Session tokens are random per side, so this order is a fair, unlinkable tie-break.
      if (!candidate.complete(now) || sessionToken.compareTo(candidate.session) >= 0
          || !attemptBudget.canAttempt(candidate.address, now)) continue;
      if (selected == null || candidate.session.compareTo(selected.session) < 0) selected = candidate;
    }
    if (selected == null) return;
    // Recheck for another app's group just before requesting a connection.
    if (now - groupCheckedAt > 5000L) { queryGroup(); return; }
    if (!attemptBudget.record(selected.address, now)) return;
    WifiP2pConfig config = new WifiP2pConfig();
    config.deviceAddress = selected.address;
    config.wps.setup = WpsInfo.PBC;
    // Android chooses the group owner and displays any required confirmation.
    // Forcing GO or deleting a preexisting group could disrupt another network.
    connecting = true;
    connectingAddress = selected.address;
    groupOwnership.requested(selected.address);
    connectStartedAt = now;
    final int token = generation;
    setState("connecting");
    try {
      manager.connect(channel, config, new WifiP2pManager.ActionListener() {
        @Override public void onSuccess() {
          if (!current(token)) return;
          // Success only means the request was accepted by Android. Wait for
          // actual connection/group information before exposing an IP route.
          queryGroup();
          emit();
        }
        @Override public void onFailure(int reason) {
          if (!current(token)) return;
          connecting = false;
          connectingAddress = "";
          groupOwnership.cancelRequest();
          lastError = "connect_" + reasonName(reason);
          setState(stateForReason(reason));
        }
      });
    } catch (RuntimeException error) {
      connecting = false;
      connectingAddress = "";
      groupOwnership.cancelRequest();
      failure("connect", error);
    }
  }

  private Candidate candidateFor(WifiP2pDevice device) {
    String address = safeMac(device);
    if (address.isEmpty()) return null;
    long now = SystemClock.elapsedRealtime();
    pruneCandidates(now);
    Candidate candidate = candidates.get(address);
    if (candidate == null) {
      if (candidates.size() >= MAX_CANDIDATES) return null;
      candidate = new Candidate(address);
      candidates.put(address, candidate);
    }
    return candidate;
  }

  private void pruneCandidates(long now) {
    Iterator<Candidate> entries = candidates.values().iterator();
    while (entries.hasNext()) {
      Candidate candidate = entries.next();
      if (now - Math.max(candidate.serviceSeenAt, candidate.txtSeenAt) > CANDIDATE_LIFETIME_MS
          && !candidate.address.equals(connectingAddress)) entries.remove();
    }
  }

  private int validServiceCount() {
    int count = 0;
    long now = SystemClock.elapsedRealtime();
    for (Candidate candidate : candidates.values()) if (candidate.complete(now)) count++;
    return count;
  }

  private void registrationFailure(String operation, int reason) {
    nextRegistrationAt = SystemClock.elapsedRealtime() + REFRESH_MS;
    lastError = operation + "_" + reasonName(reason);
    setState(stateForReason(reason));
  }

  private void failure(String operation, RuntimeException error) {
    lastError = diagnostic(operation, error);
    if (error instanceof SecurityException) {
      permissionGranted = false;
      setState("permissionRequired");
    } else setState("error");
  }

  private void cancelOwnConnect() {
    if (!connecting || channel == null) return;
    try { manager.cancelConnect(channel, null); }
    catch (RuntimeException ignored) { /* Stop/timeout must remain safe after revocation. */ }
    connecting = false;
    connectingAddress = "";
    groupOwnership.cancelRequest();
  }

  private void stopInternal(boolean notify) {
    active = false;
    autoConnectAllowed = false;
    generation++;
    handler.removeCallbacks(refreshTask);
    if (receiverRegistered) {
      try { context.unregisterReceiver(receiver); }
      catch (RuntimeException ignored) { /* Receiver may already have been detached. */ }
      receiverRegistered = false;
    }
    releaseChannel(true);
    candidates.clear();
    attemptBudget.clear();
    lastError = null;
    state = "stopped";
    if (notify) emit();
  }

  private void removeOwnDiscoveryRecords() {
    if (channel == null || manager == null) return;
    // Framework callbacks can arrive after removeLocalService/request. They
    // must not restore flags for records that this session has already removed.
    registrationSerial++;
    if ((localRegistered || localRegistering) && localService != null) {
      localRegistered = localRegistering = false;
      try { manager.removeLocalService(channel, localService, null); }
      catch (RuntimeException ignored) { /* No unrelated service is removed. */ }
    }
    if ((requestRegistered || requestRegistering) && serviceRequest != null) {
      requestRegistered = requestRegistering = false;
      try { manager.removeServiceRequest(channel, serviceRequest, null); }
      catch (RuntimeException ignored) { /* No unrelated service request is removed. */ }
    }
    discoveryRunning = false;
  }

  private void releaseChannel(boolean removeAppGroup) {
    if (channel == null) return;
    WifiP2pManager.Channel old = channel;
    WifiP2pDnsSdServiceInfo oldService = localService;
    WifiP2pDnsSdServiceRequest oldRequest = serviceRequest;
    boolean cancelPending = connecting;
    // DNS-SD hints can identify an incoming app peer, but do not establish
    // ownership of Android's shared P2P group. Only clean up a group correlated
    // with this session's own pending connect request; preserve all others.
    boolean removeGroup = removeAppGroup && groupOwnership.mayRemove(groupKey);
    generation++;
    registrationSerial++;
    channel = null;
    localService = null;
    serviceRequest = null;
    localRegistered = requestRegistered = localRegistering = requestRegistering = discoveryRunning = false;
    resetGroup();
    groupOwnership.clear();
    if (manager == null) return;
    if (cancelPending) {
      try { manager.cancelConnect(old, null); }
      catch (RuntimeException ignored) { /* Cancellation only applies to our request. */ }
    }
    if (removeGroup) {
      try { manager.removeGroup(old, null); }
      catch (RuntimeException ignored) { /* Never remove an unrelated group. */ }
    }
    if (oldService != null) {
      try { manager.removeLocalService(old, oldService, null); }
      catch (RuntimeException ignored) { /* Only our advertisement is touched. */ }
    }
    if (oldRequest != null) {
      try { manager.removeServiceRequest(old, oldRequest, null); }
      catch (RuntimeException ignored) { /* Do not clear other apps' requests. */ }
    }
    if (Build.VERSION.SDK_INT >= 27) {
      try { old.close(); }
      catch (RuntimeException ignored) { /* Framework may already have closed. */ }
    }
  }

  private void resetGroup() {
    groupKnown = false;
    groupQueryPending = false;
    groupQuerySerial++;
    connecting = false;
    connectingAddress = "";
    resetGroupDetails();
  }

  private void resetGroupDetails() {
    if (groupFormed || !groupKey.isEmpty()) groupSerial++;
    groupFormed = appGroup = isGroupOwner = false;
    groupOwnerHost = groupInterface = groupKey = "";
    localAddresses = new ArrayList<>();
    groupOwnership.clearGroup();
  }

  private boolean current(int token) { return active && generation == token && channel != null; }

  private void setState(String value) { state = value; emit(); }

  private void emit() { listener.onState(snapshot()); }

  private static void requireMainThread() {
    if (Looper.myLooper() != Looper.getMainLooper()) throw new IllegalStateException("Wi-Fi Direct must run on main thread");
  }

  static boolean isAppService(String instance, String type) {
    if (instance == null || type == null || !INSTANCE.equalsIgnoreCase(instance)) return false;
    String normalized = normalizeDns(type);
    return SERVICE_TYPE.equals(normalized) || (SERVICE_TYPE + ".local").equals(normalized);
  }

  static boolean isAppDomain(String domain) {
    if (domain == null) return false;
    String normalized = normalizeDns(domain);
    return (INSTANCE + "." + SERVICE_TYPE + ".local").equals(normalized)
        || (INSTANCE + "." + SERVICE_TYPE).equals(normalized);
  }

  /** TXT v2: {@code sid} is a rotating session token; a v1 {@code id} fingerprint is no longer accepted. */
  static String validSession(Map<String, String> records) {
    if (records == null || records.size() > 8 || !"farvahartrends".equals(records.get("app"))
        || !"2".equals(records.get("v")) || records.containsKey("id")) return null;
    String session = records.get("sid");
    return session != null && SESSION_PATTERN.matcher(session).matches() ? session : null;
  }

  static int validPort(Map<String, String> records) {
    if (validSession(records) == null) return 0;
    String port = records.get("port");
    if (port == null || !port.matches("[0-9]{1,5}")) return 0;
    try {
      int value = Integer.parseInt(port);
      return value >= 1 && value <= 65535 ? value : 0;
    } catch (NumberFormatException ignored) { return 0; }
  }

  private static String normalizeDns(String value) {
    if (value.length() > 128) return "";
    String normalized = value.toLowerCase(Locale.ROOT);
    return normalized.endsWith(".") ? normalized.substring(0, normalized.length() - 1) : normalized;
  }

  private static String safeMac(WifiP2pDevice device) {
    if (device == null || device.deviceAddress == null) return "";
    String address = device.deviceAddress.toLowerCase(Locale.ROOT);
    return MAC_PATTERN.matcher(address).matches() && !"00:00:00:00:00:00".equals(address)
        && !"02:00:00:00:00:00".equals(address) ? address : "";
  }

  private static List<Map<String, Object>> interfaceAddresses(String interfaceName) {
    if (interfaceName.isEmpty()) return Collections.emptyList();
    List<Map<String, Object>> result = new ArrayList<>();
    try {
      NetworkInterface network = NetworkInterface.getByName(interfaceName);
      if (network == null) return result;
      for (InterfaceAddress entry : network.getInterfaceAddresses()) {
        InetAddress address = entry.getAddress();
        if (address == null || address.isLoopbackAddress() || address.isAnyLocalAddress()) continue;
        Map<String, Object> item = new HashMap<>();
        item.put("address", address.getHostAddress());
        item.put("prefixLength", (int) entry.getNetworkPrefixLength());
        result.add(item);
        if (result.size() >= 8) break;
      }
    } catch (SocketException | SecurityException ignored) { /* Route metadata is optional. */ }
    return result;
  }

  private static String reasonName(int reason) {
    if (reason == WifiP2pManager.P2P_UNSUPPORTED) return "unsupported";
    if (reason == WifiP2pManager.BUSY) return "busy";
    if (reason == WifiP2pManager.NO_SERVICE_REQUESTS) return "no_service_request";
    // NO_PERMISSION was introduced after older supported Android versions.
    if (reason == 4) return "permission_denied";
    return "error_" + reason;
  }

  private static String stateForReason(int reason) {
    if (reason == WifiP2pManager.P2P_UNSUPPORTED) return "unsupported";
    if (reason == 4) return "permissionRequired";
    return "error";
  }

  private static String diagnostic(String operation, RuntimeException error) {
    // Never include exception messages: they can contain MACs, addresses or
    // framework details identifying nearby devices.
    return operation + (error instanceof SecurityException ? "_permission_denied"
        : error instanceof IllegalArgumentException ? "_invalid_argument" : "_unavailable");
  }

  private static final class Candidate {
    final String address;
    String session = "";
    int port;
    long serviceSeenAt = -CANDIDATE_LIFETIME_MS - 1;
    long txtSeenAt = -CANDIDATE_LIFETIME_MS - 1;
    Candidate(String address) { this.address = address; }
    boolean complete(long now) {
      return !session.isEmpty() && port > 0 && now - serviceSeenAt <= CANDIDATE_LIFETIME_MS
          && now - txtSeenAt <= CANDIDATE_LIFETIME_MS;
    }
  }

  private static final class GroupQuery {
    WifiP2pInfo info;
    WifiP2pGroup group;
    boolean infoReceived;
    boolean groupReceived;
  }

  /** Conservative correlation, not exclusive ownership of the OS-wide group. */
  static final class GroupOwnership {
    private String requestedAddress = "", ownedKey = "";
    void requested(String address) { requestedAddress = address; }
    void cancelRequest() { requestedAddress = ""; }
    void observed(String key, Iterable<String> members) {
      if (!ownedKey.isEmpty() && ownedKey.equals(key)) return;
      ownedKey = "";
      if (!requestedAddress.isEmpty()) {
        for (String address : members) {
          if (requestedAddress.equals(address)) { ownedKey = key; break; }
        }
      }
      requestedAddress = "";
    }
    boolean mayRemove(String key) { return !ownedKey.isEmpty() && ownedKey.equals(key); }
    void clearGroup() { ownedKey = ""; }
    void clear() { requestedAddress = ownedKey = ""; }
  }

  /** Per-activation prompt budget survives expiry of discovered candidates. */
  static final class AttemptBudget {
    private static final int MAX_TOTAL = 4;
    private static final long COOLDOWN_MS = 120000L;
    private final Map<String, Integer> counts = new HashMap<>();
    private final Map<String, Long> lastAt = new HashMap<>();
    private int total;
    boolean canAttempt(String address, long now) {
      int count = counts.containsKey(address) ? counts.get(address) : 0;
      Long last = lastAt.get(address);
      return total < MAX_TOTAL && count < 2 && (last == null || now - last >= COOLDOWN_MS);
    }
    boolean record(String address, long now) {
      if (!canAttempt(address, now)) return false;
      counts.put(address, counts.containsKey(address) ? counts.get(address) + 1 : 1);
      lastAt.put(address, now);
      total++;
      return true;
    }
    int remaining() { return MAX_TOTAL - total; }
    void clear() { counts.clear(); lastAt.clear(); total = 0; }
  }
}
