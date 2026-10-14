package org.farvahartrends.platform;

import java.util.concurrent.ArrayBlockingQueue;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.ThreadPoolExecutor;
import java.util.concurrent.TimeUnit;

/** Owned, bounded resources shared by the BLE tunnel and host-only tests. */
final class BleRuntime {
  private BleRuntime() {}

  static ExecutorService newIoExecutor() {
    return new ThreadPoolExecutor(3, 3, 0L, TimeUnit.MILLISECONDS,
        new ArrayBlockingQueue<>(6), task -> {
          Thread thread = new Thread(task, "FarvaharTrends-BLE-IO");
          thread.setDaemon(true);
          return thread;
        }, new ThreadPoolExecutor.AbortPolicy());
  }

  interface Scheduler {
    void postDelayed(Runnable callback, long delayMs);
    void remove(Runnable callback);
  }

  /** At most one pending callback; cancellation also invalidates dequeued work. */
  static final class Deadline {
    private final Scheduler scheduler;
    private Runnable pending;

    Deadline(Scheduler scheduler) { this.scheduler = scheduler; }

    void arm(long delayMs, Runnable callback) {
      cancel();
      Runnable owned = new Runnable() {
        @Override public void run() {
          if (pending != this) return;
          pending = null;
          callback.run();
        }
      };
      pending = owned;
      scheduler.postDelayed(owned, delayMs);
    }

    void cancel() {
      Runnable owned = pending;
      pending = null;
      if (owned != null) scheduler.remove(owned);
    }
  }
}
