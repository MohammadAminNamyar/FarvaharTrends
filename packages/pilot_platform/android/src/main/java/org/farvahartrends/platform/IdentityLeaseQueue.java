package org.farvahartrends.platform;

import java.security.SecureRandom;
import java.util.ArrayDeque;
import java.util.IdentityHashMap;

/**
 * Process-wide identity-creation exclusion, independent of Flutter isolates.
 * All calls and scheduled callbacks must run on the Android main thread. The
 * helper has no Android dependency so lifecycle races can be tested on a JVM.
 */
public final class IdentityLeaseQueue {
  public static final int MAX_PENDING = 4;
  public static final long PENDING_TIMEOUT_MS = 45000;

  public interface Scheduler {
    void postDelayed(Runnable task, long delayMillis);
    void remove(Runnable task);
  }

  public interface Callback {
    void granted(String token);
    void failed(String code);
  }

  private final Scheduler scheduler;
  private final SecureRandom random = new SecureRandom();
  private final ArrayDeque<Request> pending = new ArrayDeque<>();
  private final IdentityHashMap<Object, Request> requests = new IdentityHashMap<>();
  private Request active;

  public IdentityLeaseQueue(Scheduler scheduler) {
    if (scheduler == null) throw new IllegalArgumentException("Scheduler required");
    this.scheduler = scheduler;
  }

  public void acquire(Object owner, Callback callback) {
    if (owner == null || callback == null) throw new IllegalArgumentException("Owner and callback required");
    if (requests.containsKey(owner)) {
      fail(callback, "identity_lease_busy");
      return;
    }
    if (active != null && pending.size() >= MAX_PENDING) {
      fail(callback, "identity_lease_queue_full");
      return;
    }
    Request request = new Request(owner, callback, newToken());
    requests.put(owner, request);
    pending.addLast(request);
    if (active == null) {
      grantNext();
    } else {
      request.timeout = () -> timeout(request);
      scheduler.postDelayed(request.timeout, PENDING_TIMEOUT_MS);
    }
  }

  /** A stale or foreign token never releases another attachment's lease. */
  public boolean release(Object owner, String token) {
    if (active == null || active.owner != owner || !active.token.equals(token)) return false;
    requests.remove(owner);
    active = null;
    grantNext();
    return true;
  }

  /** Called only when the owning Flutter engine detaches, not Activity rotation. */
  public void detach(Object owner) {
    Request request = requests.remove(owner);
    if (request == null) return;
    if (request == active) {
      active = null;
    } else {
      pending.remove(request);
      cancelTimeout(request);
      fail(request.callback, "identity_lease_detached");
    }
    grantNext();
  }

  public int pendingCount() { return pending.size(); }

  public boolean ownedBy(Object owner, String token) {
    return active != null && active.owner == owner && active.token.equals(token);
  }

  private void timeout(Request request) {
    // A dequeued timeout can run after cancellation or after this owner readds.
    // Compare the exact request, not just its attachment or token.
    if (request == active || requests.get(request.owner) != request) return;
    requests.remove(request.owner);
    pending.remove(request);
    cancelTimeout(request);
    fail(request.callback, "identity_lease_timeout");
    grantNext();
  }

  private void grantNext() {
    if (active != null) return;
    while (active == null && !pending.isEmpty()) {
      Request request = pending.removeFirst();
      if (requests.get(request.owner) != request) continue;
      cancelTimeout(request);
      active = request;
      try {
        // Active leases never expire while RSA generation or vault writes await.
        request.callback.granted(request.token);
        return;
      } catch (RuntimeException ignored) {
        // A detached messenger must not strand the process-wide identity lock.
        if (active == request) {
          requests.remove(request.owner);
          active = null;
        }
      }
    }
  }

  private void cancelTimeout(Request request) {
    if (request.timeout == null) return;
    scheduler.remove(request.timeout);
    request.timeout = null;
  }

  private static void fail(Callback callback, String code) {
    try { callback.failed(code); }
    catch (RuntimeException ignored) { /* The engine may already be detached. */ }
  }

  private String newToken() {
    byte[] bytes = new byte[32];
    random.nextBytes(bytes);
    char[] hex = "0123456789abcdef".toCharArray();
    char[] result = new char[64];
    for (int i = 0; i < bytes.length; i++) {
      int value = bytes[i] & 255;
      result[i * 2] = hex[value >>> 4];
      result[i * 2 + 1] = hex[value & 15];
    }
    return new String(result);
  }

  private static final class Request {
    final Object owner;
    final Callback callback;
    final String token;
    Runnable timeout;
    Request(Object owner, Callback callback, String token) {
      this.owner = owner;
      this.callback = callback;
      this.token = token;
    }
  }
}
