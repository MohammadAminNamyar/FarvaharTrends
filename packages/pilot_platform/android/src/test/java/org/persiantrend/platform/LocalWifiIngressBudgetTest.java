package org.persiantrend.platform;

/** Standalone JVM checks: one real LAN source cannot consume every proxy slot/quota. */
public final class LocalWifiIngressBudgetTest {
  private static int assertions;

  public static void main(String[] args) {
    LocalWifiIngressBudget budget = new LocalWifiIngressBudget();
    for (int i = 0; i < 16; i++) check(budget.allow("192.168.1.2", 1000, 0, 0), "source budget available");
    check(!budget.allow("192.168.1.2", 1001, 0, 0), "single source stopped before global budget");
    check(budget.allow("192.168.1.3", 1001, 0, 0), "other source still admitted");
    for (int i = 0; i < 47; i++) check(budget.allow("10.0.0." + i, 1001, 0, 0), "remaining global budget");
    check(!budget.allow("192.168.1.4", 1002, 0, 0), "global cap enforced");
    check(budget.trackedSources() <= LocalWifiIngressBudget.MAX_SOURCES, "source table bounded");
    check(!budget.allow("192.168.1.2", 60999, 0, 0), "window cannot reset early");
    check(budget.allow("192.168.1.2", 61000, 0, 0), "window expires at boundary");
    check(budget.trackedSources() == 1, "expired source addresses discarded");

    budget.reset();
    check(!budget.allow("192.168.1.2", 10, 4, 4), "four inbound flows reserve outbound capacity");
    check(!budget.allow("192.168.1.2", 10, 0, 8), "total flow cap enforced");
    check(budget.trackedSources() == 0, "capacity rejection never creates source records");
    for (int i = 0; i < 16; i++) check(budget.allow("192.168.1.2", 10, 3, 7), "capacity rejection does not consume quota");
    check(!budget.allow("192.168.1.2", 10, 3, 7), "source quota remains exact");

    budget.reset();
    for (int i = 0; i < 10000; i++) budget.allow("source-" + i, 50, 0, 0);
    check(budget.trackedSources() == 64, "many spoofed sources cannot grow the table beyond global cap");
    check(budget.allow("next-window", 60050, 0, 0), "new window restores admission");
    check(budget.trackedSources() == 1, "new window clears spoofed identities");
    check(budget.allow("clock-restart", 0, 0, 0), "monotonic restart resets state safely");
    check(budget.trackedSources() == 1, "clock reset clears prior addresses");
    check(!budget.allow(null, 0, 0, 0), "null source rejected");
    check(!budget.allow("", 0, 0, 0), "empty source rejected");
    check(!budget.allow("a".repeat(65), 0, 0, 0), "oversized source rejected");
    check(!budget.allow("192.168.1.2", -1, 0, 0), "invalid monotonic time rejected");
    check(!budget.allow("192.168.1.2", 0, -1, 0), "invalid incoming count rejected");
    check(!budget.allow("192.168.1.2", 0, 0, -1), "invalid total count rejected");
    budget.reset();
    check(budget.trackedSources() == 0, "stop clears all addresses");
    System.out.println("Local Wi-Fi ingress budget checks passed (" + assertions + " assertions).");
  }

  private static void check(boolean value, String description) {
    assertions++;
    if (!value) throw new AssertionError(description);
  }
}
