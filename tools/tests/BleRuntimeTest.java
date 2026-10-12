package org.persiantrend.platform;

import java.util.ArrayList;
import java.util.List;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.RejectedExecutionException;
import java.util.concurrent.TimeUnit;

/** Host JVM regression tests; no Bluetooth hardware or Android runtime used. */
public final class BleRuntimeTest {
  public static void main(String[] args) throws Exception {
    List<Runnable> pending = new ArrayList<>();
    BleRuntime.Scheduler scheduler = new BleRuntime.Scheduler() {
      public void postDelayed(Runnable task, long delay) { pending.add(task); }
      public void remove(Runnable task) { pending.remove(task); }
    };
    BleRuntime.Deadline deadline = new BleRuntime.Deadline(scheduler);
    int[] fired = {0};
    for (int i = 0; i < 10000; i++) {
      deadline.arm(20000, () -> fired[0]++);
      check(pending.size() == 1, "one owned timeout per operation");
      Runnable dequeued = pending.get(0);
      deadline.cancel();
      dequeued.run();
      check(pending.isEmpty() && fired[0] == 0, "completed/canceled operation cannot fire");
    }
    deadline.arm(1, () -> fired[0]++);
    Runnable replaced = pending.get(0);
    deadline.arm(1, () -> fired[0]++);
    replaced.run();
    check(fired[0] == 0 && pending.size() == 1, "replacement invalidates old callback");
    Runnable current = pending.remove(0);
    current.run(); current.run();
    check(fired[0] == 1, "deadline runs at most once");

    ExecutorService io = BleRuntime.newIoExecutor();
    CountDownLatch started = new CountDownLatch(3), release = new CountDownLatch(1);
    try {
      for (int i = 0; i < 3; i++) io.execute(() -> {
        started.countDown();
        try { release.await(); } catch (InterruptedException ignored) { Thread.currentThread().interrupt(); }
      });
      check(started.await(2, TimeUnit.SECONDS), "three bounded workers start");
      for (int i = 0; i < 6; i++) io.execute(() -> {});
      boolean rejected = false;
      try { io.execute(() -> {}); } catch (RejectedExecutionException expected) { rejected = true; }
      check(rejected, "stalled links cannot create unbounded pending IO tasks");
    } finally {
      release.countDown();
      io.shutdownNow();
      check(io.awaitTermination(2, TimeUnit.SECONDS), "workers terminate after teardown");
    }
    System.out.println("BLE owned deadline and bounded-worker regressions passed.");
  }
  private static void check(boolean value, String message) {
    if (!value) throw new AssertionError(message);
  }
}
