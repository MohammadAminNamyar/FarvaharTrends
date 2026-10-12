package org.persiantrend.platform;

import java.util.ArrayList;
import java.util.HashSet;
import java.util.List;
import java.util.Set;

/** Pure JVM lifecycle tests; no Android runtime, device state, or vault secrets. */
public final class IdentityLeaseQueueTest {
  private static int assertions;
  private static void check(boolean value, String message) {
    assertions++;
    if (!value) throw new AssertionError(message);
  }

  private static final class Scheduler implements IdentityLeaseQueue.Scheduler {
    final List<Runnable> tasks = new ArrayList<>();
    public void postDelayed(Runnable task, long delay) {
      check(delay == 45000, "pending lease timeout is bounded");
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

  public static void main(String[] args) {
    Scheduler scheduler = new Scheduler();
    IdentityLeaseQueue leases = new IdentityLeaseQueue(scheduler);
    Object a = new Object(), b = new Object(), c = new Object();
    Callback first = new Callback(), second = new Callback();
    leases.acquire(a, first);
    check(first.token().matches("[a-f0-9]{64}"), "unpredictable lease token shape");
    check(scheduler.tasks.isEmpty(), "active identity generation has no deadline");
    Callback repeated = new Callback();
    leases.acquire(a, repeated);
    check(repeated.errors.equals(List.of("identity_lease_busy")), "one request per attachment");
    leases.acquire(b, second);
    check(second.tokens.isEmpty() && leases.pendingCount() == 1, "second engine cannot generate concurrently");
    Runnable oldBTimeout = scheduler.tasks.get(0);
    check(!leases.release(b, first.token()), "foreign attachment cannot release active lease");
    check(!leases.release(a, "wrong"), "wrong token cannot release active lease");
    check(leases.ownedBy(a, first.token()), "rejected releases preserve original owner");
    check(leases.release(a, first.token()), "exact owner releases");
    check(second.tokens.size() == 1 && leases.ownedBy(b, second.token()), "FIFO grant after release");
    oldBTimeout.run();
    check(second.errors.isEmpty() && leases.ownedBy(b, second.token()), "stale timeout cannot revoke active lease");
    check(scheduler.tasks.isEmpty(), "grant cancels queued timer");
    check(!leases.release(a, first.token()), "double release cannot release successor");

    List<Object> queuedOwners = new ArrayList<>();
    for (int i = 0; i < IdentityLeaseQueue.MAX_PENDING; i++) {
      Object owner = new Object();
      queuedOwners.add(owner);
      leases.acquire(owner, new Callback());
    }
    Callback overflow = new Callback();
    leases.acquire(c, overflow);
    check(overflow.errors.equals(List.of("identity_lease_queue_full")), "queue bound enforced without orphaned owner");
    check(leases.pendingCount() == 4 && scheduler.tasks.size() == 4, "pending memory and timers bounded");
    for (Object owner : queuedOwners) leases.detach(owner);
    check(leases.pendingCount() == 0 && scheduler.tasks.isEmpty(), "queued detach cancels all timers");

    Callback expiring = new Callback();
    leases.acquire(a, expiring);
    Runnable stale = scheduler.tasks.get(0);
    stale.run();
    stale.run();
    check(expiring.errors.equals(List.of("identity_lease_timeout")), "timeout errors exactly once");
    Callback replacement = new Callback();
    leases.acquire(a, replacement);
    stale.run();
    check(replacement.errors.isEmpty() && leases.pendingCount() == 1, "old callback cannot cancel a replacement request");
    leases.detach(b);
    check(replacement.tokens.size() == 1, "owning engine detach grants successor");
    check(!leases.release(b, second.token()), "detached owner's token is permanently stale");
    String previousToken = replacement.token();
    leases.detach(a);
    Callback reattached = new Callback();
    leases.acquire(a, reattached);
    check(!reattached.token().equals(previousToken), "reattachment receives a fresh token");
    check(!leases.release(a, previousToken), "old token cannot release same object's later lease");
    check(leases.ownedBy(a, reattached.token()), "stale token preserves new active owner");

    Callback detachedPending = new Callback();
    leases.acquire(b, detachedPending);
    Runnable detachedTimeout = scheduler.tasks.get(0);
    leases.detach(b);
    leases.detach(b);
    detachedTimeout.run();
    check(detachedPending.errors.equals(List.of("identity_lease_detached")), "pending detach completes exactly once");
    check(detachedPending.tokens.isEmpty(), "detached request never receives a token");
    leases.release(a, reattached.token());

    leases.acquire(c, new IdentityLeaseQueue.Callback() {
      public void granted(String token) { throw new IllegalStateException("detached messenger"); }
      public void failed(String code) {}
    });
    Callback afterBrokenMessenger = new Callback();
    leases.acquire(b, afterBrokenMessenger);
    check(afterBrokenMessenger.tokens.size() == 1, "failed callback cannot strand process-wide lease");
    leases.release(b, afterBrokenMessenger.token());

    Set<String> seen = new HashSet<>();
    for (int i = 0; i < 1000; i++) {
      Callback callback = new Callback();
      leases.acquire(a, callback);
      check(seen.add(callback.token()), "tokens are not reused during lifecycle churn");
      check(leases.release(a, callback.token()), "churn releases exact active request");
    }
    check(leases.pendingCount() == 0 && scheduler.tasks.isEmpty(), "churn leaves no pending requests or timers");
    System.out.println("Identity lease lifecycle regressions passed (" + assertions + " checks).");
  }
}
