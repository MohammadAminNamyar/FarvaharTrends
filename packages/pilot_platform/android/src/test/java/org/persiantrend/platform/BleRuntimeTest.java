package org.persiantrend.platform;

import org.junit.Test;
import static org.junit.Assert.*;

import java.util.ArrayList;
import java.util.List;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.RejectedExecutionException;
import java.util.concurrent.TimeUnit;

/** Host JVM regression tests; no Bluetooth hardware or Android runtime used. */
public final class BleRuntimeTest {
  @Test
  public void regressionChecks() throws Exception {
    List<Runnable> pending = new ArrayList<>();
    BleRuntime.Scheduler scheduler = new BleRuntime.Scheduler() {
      public void postDelayed(Runnable task, long delay) { pending.add(task); }
      public void remove(Runnable task) { pending.remove(task); }
    };
    BleRuntime.Deadline deadline = new BleRuntime.Deadline(scheduler);
    int[] fired = {0};
    for (int i = 0; i < 10000; i++) {
      deadline.arm(20000, () -> fired[0]++);
      assertTrue("one owned timeout per operation", pending.size() == 1);
      Runnable dequeued = pending.get(0);
      deadline.cancel();
      dequeued.run();
      assertTrue("completed/canceled operation cannot fire", pending.isEmpty() && fired[0] == 0);
    }
    deadline.arm(1, () -> fired[0]++);
    Runnable replaced = pending.get(0);
    deadline.arm(1, () -> fired[0]++);
    replaced.run();
    assertTrue("replacement invalidates old callback", fired[0] == 0 && pending.size() == 1);
    Runnable current = pending.remove(0);
    current.run(); current.run();
    assertTrue("deadline runs at most once", fired[0] == 1);

    ExecutorService io = BleRuntime.newIoExecutor();
    CountDownLatch started = new CountDownLatch(3), release = new CountDownLatch(1);
    try {
      for (int i = 0; i < 3; i++) io.execute(() -> {
        started.countDown();
        try { release.await(); } catch (InterruptedException ignored) { Thread.currentThread().interrupt(); }
      });
      assertTrue("three bounded workers start", started.await(2, TimeUnit.SECONDS));
      for (int i = 0; i < 6; i++) io.execute(() -> {});
      boolean rejected = false;
      try { io.execute(() -> {}); } catch (RejectedExecutionException expected) { rejected = true; }
      assertTrue("stalled links cannot create unbounded pending IO tasks", rejected);
    } finally {
      release.countDown();
      io.shutdownNow();
      assertTrue("workers terminate after teardown", io.awaitTermination(2, TimeUnit.SECONDS));
    }

  }
}
