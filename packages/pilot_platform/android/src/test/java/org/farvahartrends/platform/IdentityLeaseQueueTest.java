package org.farvahartrends.platform;

import org.junit.Test;
import static org.junit.Assert.*;

import java.util.ArrayList;
import java.util.HashSet;
import java.util.List;
import java.util.Set;

/** Pure JVM lifecycle tests; no Android runtime, device state, or vault secrets. */
public final class IdentityLeaseQueueTest {
  private static final class Scheduler implements IdentityLeaseQueue.Scheduler {
    final List<Runnable> tasks = new ArrayList<>();
    public void postDelayed(Runnable task, long delay) {
      assertTrue("pending lease timeout is bounded", delay == 45000);
      tasks.add(task);
    }
    public void remove(Runnable task) { tasks.remove(task); }
  }

  private static final class Callback implements IdentityLeaseQueue.Callback {
    final List<String> tokens = new ArrayList<>();
    final List<String> errors = new ArrayList<>();
    public void granted(String token) { tokens.add(token); }
    public void failed(String code) { errors.add(code); }
    String token() { return tokens.get(tokens.size() - 1); }
  }

  @Test
  public void regressionChecks() {
    Scheduler scheduler = new Scheduler();
    IdentityLeaseQueue leases = new IdentityLeaseQueue(scheduler);
    Object a = new Object(), b = new Object(), c = new Object();
    Callback first = new Callback(), second = new Callback();
    leases.acquire(a, first);
    assertTrue("unpredictable lease token shape", first.token().matches("[a-f0-9]{64}"));
    assertTrue("active identity generation has no deadline", scheduler.tasks.isEmpty());
    Callback repeated = new Callback();
    leases.acquire(a, repeated);
    assertTrue("one request per attachment", repeated.errors.equals(List.of("identity_lease_busy")));
    leases.acquire(b, second);
    assertTrue("second engine cannot generate concurrently", second.tokens.isEmpty() && leases.pendingCount() == 1);
    Runnable oldBTimeout = scheduler.tasks.get(0);
    assertTrue("foreign attachment cannot release active lease", !leases.release(b, first.token()));
    assertTrue("wrong token cannot release active lease", !leases.release(a, "wrong"));
    assertTrue("rejected releases preserve original owner", leases.ownedBy(a, first.token()));
    assertTrue("exact owner releases", leases.release(a, first.token()));
    assertTrue("FIFO grant after release", second.tokens.size() == 1 && leases.ownedBy(b, second.token()));
    oldBTimeout.run();
    assertTrue("stale timeout cannot revoke active lease", second.errors.isEmpty() && leases.ownedBy(b, second.token()));
    assertTrue("grant cancels queued timer", scheduler.tasks.isEmpty());
    assertTrue("double release cannot release successor", !leases.release(a, first.token()));

    List<Object> queuedOwners = new ArrayList<>();
    for (int i = 0; i < IdentityLeaseQueue.MAX_PENDING; i++) {
      Object owner = new Object();
      queuedOwners.add(owner);
      leases.acquire(owner, new Callback());
    }
    Callback overflow = new Callback();
    leases.acquire(c, overflow);
    assertTrue("queue bound enforced without orphaned owner", overflow.errors.equals(List.of("identity_lease_queue_full")));
    assertTrue("pending memory and timers bounded", leases.pendingCount() == 4 && scheduler.tasks.size() == 4);
    for (Object owner : queuedOwners) leases.detach(owner);
    assertTrue("queued detach cancels all timers", leases.pendingCount() == 0 && scheduler.tasks.isEmpty());

    Callback expiring = new Callback();
    leases.acquire(a, expiring);
    Runnable stale = scheduler.tasks.get(0);
    stale.run();
    stale.run();
    assertTrue("timeout errors exactly once", expiring.errors.equals(List.of("identity_lease_timeout")));
    Callback replacement = new Callback();
    leases.acquire(a, replacement);
    stale.run();
    assertTrue("old callback cannot cancel a replacement request", replacement.errors.isEmpty() && leases.pendingCount() == 1);
    leases.detach(b);
    assertTrue("owning engine detach grants successor", replacement.tokens.size() == 1);
    assertTrue("detached owner's token is permanently stale", !leases.release(b, second.token()));
    String previousToken = replacement.token();
    leases.detach(a);
    Callback reattached = new Callback();
    leases.acquire(a, reattached);
    assertTrue("reattachment receives a fresh token", !reattached.token().equals(previousToken));
    assertTrue("old token cannot release same object's later lease", !leases.release(a, previousToken));
    assertTrue("stale token preserves new active owner", leases.ownedBy(a, reattached.token()));

    Callback detachedPending = new Callback();
    leases.acquire(b, detachedPending);
    Runnable detachedTimeout = scheduler.tasks.get(0);
    leases.detach(b);
    leases.detach(b);
    detachedTimeout.run();
    assertTrue("pending detach completes exactly once", detachedPending.errors.equals(List.of("identity_lease_detached")));
    assertTrue("detached request never receives a token", detachedPending.tokens.isEmpty());
    leases.release(a, reattached.token());

    leases.acquire(c, new IdentityLeaseQueue.Callback() {
      public void granted(String token) { throw new IllegalStateException("detached messenger"); }
      public void failed(String code) {}
    });
    Callback afterBrokenMessenger = new Callback();
    leases.acquire(b, afterBrokenMessenger);
    assertTrue("failed callback cannot strand process-wide lease", afterBrokenMessenger.tokens.size() == 1);
    leases.release(b, afterBrokenMessenger.token());

    Set<String> seen = new HashSet<>();
    for (int i = 0; i < 1000; i++) {
      Callback callback = new Callback();
      leases.acquire(a, callback);
      assertTrue("tokens are not reused during lifecycle churn", seen.add(callback.token()));
      assertTrue("churn releases exact active request", leases.release(a, callback.token()));
    }
    assertTrue("churn leaves no pending requests or timers", leases.pendingCount() == 0 && scheduler.tasks.isEmpty());

  }
}
