package org.persiantrend.platform;

import org.junit.Test;
import static org.junit.Assert.*;

/** Standalone JVM checks: one real LAN source cannot consume every proxy slot/quota. */
public final class LocalWifiIngressBudgetTest {
  @Test
  public void regressionChecks() {
    LocalWifiIngressBudget budget = new LocalWifiIngressBudget();
    for (int i = 0; i < 16; i++) assertTrue("source budget available", budget.allow("192.168.1.2", 1000, 0, 0));
    assertTrue("single source stopped before global budget", !budget.allow("192.168.1.2", 1001, 0, 0));
    assertTrue("other source still admitted", budget.allow("192.168.1.3", 1001, 0, 0));
    for (int i = 0; i < 47; i++) assertTrue("remaining global budget", budget.allow("10.0.0." + i, 1001, 0, 0));
    assertTrue("global cap enforced", !budget.allow("192.168.1.4", 1002, 0, 0));
    assertTrue("source table bounded", budget.trackedSources() <= LocalWifiIngressBudget.MAX_SOURCES);
    assertTrue("window cannot reset early", !budget.allow("192.168.1.2", 60999, 0, 0));
    assertTrue("window expires at boundary", budget.allow("192.168.1.2", 61000, 0, 0));
    assertTrue("expired source addresses discarded", budget.trackedSources() == 1);

    budget.reset();
    assertTrue("four inbound flows reserve outbound capacity", !budget.allow("192.168.1.2", 10, 4, 4));
    assertTrue("total flow cap enforced", !budget.allow("192.168.1.2", 10, 0, 8));
    assertTrue("capacity rejection never creates source records", budget.trackedSources() == 0);
    for (int i = 0; i < 16; i++) assertTrue("capacity rejection does not consume quota", budget.allow("192.168.1.2", 10, 3, 7));
    assertTrue("source quota remains exact", !budget.allow("192.168.1.2", 10, 3, 7));

    budget.reset();
    for (int i = 0; i < 10000; i++) budget.allow("source-" + i, 50, 0, 0);
    assertTrue("many spoofed sources cannot grow the table beyond global cap", budget.trackedSources() == 64);
    assertTrue("new window restores admission", budget.allow("next-window", 60050, 0, 0));
    assertTrue("new window clears spoofed identities", budget.trackedSources() == 1);
    assertTrue("monotonic restart resets state safely", budget.allow("clock-restart", 0, 0, 0));
    assertTrue("clock reset clears prior addresses", budget.trackedSources() == 1);
    assertTrue("null source rejected", !budget.allow(null, 0, 0, 0));
    assertTrue("empty source rejected", !budget.allow("", 0, 0, 0));
    assertTrue("oversized source rejected", !budget.allow("a".repeat(65), 0, 0, 0));
    assertTrue("invalid monotonic time rejected", !budget.allow("192.168.1.2", -1, 0, 0));
    assertTrue("invalid incoming count rejected", !budget.allow("192.168.1.2", 0, -1, 0));
    assertTrue("invalid total count rejected", !budget.allow("192.168.1.2", 0, 0, -1));
    budget.reset();
    assertTrue("stop clears all addresses", budget.trackedSources() == 0);

  }

}
