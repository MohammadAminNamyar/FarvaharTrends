package org.persiantrend.platform;

import org.junit.Test;
import static org.junit.Assert.*;

import java.util.HashMap;
import java.util.Map;

/** Standalone JVM checks for admission hints and bounded automatic connection attempts. */
public final class WiFiDirectTransportRulesTest {
  @Test
  public void regressionChecks() {
    assertTrue("DNS is case insensitive", WiFiDirectTransport.isAppService("PersianTrend", "_persiantrend._tcp."));
    assertTrue("Android local suffix", WiFiDirectTransport.isAppService("persiantrend", "_persiantrend._tcp.local."));
    assertTrue("other instance rejected", !WiFiDirectTransport.isAppService("printer", "_persiantrend._tcp"));
    assertTrue("other service rejected", !WiFiDirectTransport.isAppService("persiantrend", "_http._tcp"));
    assertTrue("instance prefix rejected", !WiFiDirectTransport.isAppService("persiantrend.evil", "_persiantrend._tcp"));
    assertTrue("exact TXT domain accepted", WiFiDirectTransport.isAppDomain("PersianTrend._persiantrend._tcp.local."));
    assertTrue("TXT domain suffix rejected", !WiFiDirectTransport.isAppDomain("persiantrend._persiantrend._tcp.local.evil."));
    assertTrue("null TXT domain rejected", !WiFiDirectTransport.isAppDomain(null));

    Map<String, String> txt = validRecord();
    assertTrue("public fingerprint parsed", WiFiDirectTransport.validIdentity(txt) != null);
    assertTrue("service port parsed", WiFiDirectTransport.validPort(txt) == 45871);
    txt.put("app", "other");
    assertTrue("other app rejected", WiFiDirectTransport.validIdentity(txt) == null);
    txt = validRecord();
    txt.put("id", "a".repeat(63));
    assertTrue("short fingerprint rejected", WiFiDirectTransport.validIdentity(txt) == null);
    txt = validRecord();
    txt.put("v", "2");
    assertTrue("unknown version rejected", WiFiDirectTransport.validIdentity(txt) == null);
    for (String invalid : new String[]{"0", "65536", "-1", "45871x", " 45871", "99999999999"}) {
      txt = validRecord();
      txt.put("port", invalid);
      assertTrue("invalid port rejected: " + invalid, WiFiDirectTransport.validPort(txt) == 0);
    }
    txt = validRecord();
    for (int i = 0; i < 5; i++) txt.put("extra" + i, "ignored");
    assertTrue("overlarge TXT key map rejected", WiFiDirectTransport.validIdentity(txt) == null);

    WiFiDirectTransport.AttemptBudget budget = new WiFiDirectTransport.AttemptBudget();
    assertTrue("first request allowed", budget.record("peer-a", 1000));
    assertTrue("monotonic cooldown enforced", !budget.record("peer-a", 120999));
    assertTrue("backward elapsed value cannot bypass cooldown", !budget.record("peer-a", 0));
    assertTrue("second request allowed after cooldown", budget.record("peer-a", 121000));
    assertTrue("same peer limited to two requests", !budget.record("peer-a", 999999));
    assertTrue("second device allowed", budget.record("peer-b", 122000));
    assertTrue("fourth total request allowed", budget.record("peer-c", 123000));
    assertTrue("global prompt budget enforced", !budget.record("peer-d", 999999));
    assertTrue("no automatic attempts remain", budget.remaining() == 0);
    budget.clear();
    assertTrue("explicit new activation resets budget", budget.remaining() == 4 && budget.record("peer-a", 1000000));

    WiFiDirectTransport.GroupOwnership ownership = new WiFiDirectTransport.GroupOwnership();
    ownership.observed("existing-group", java.util.List.of("app-peer"));
    assertTrue("app discovery hints cannot authorize deleting preexisting group", !ownership.mayRemove("existing-group"));
    ownership.requested("requested-peer");
    ownership.clearGroup();
    ownership.observed("our-group", java.util.List.of("requested-peer"));
    assertTrue("formed group correlated with our own request can be cleaned up", ownership.mayRemove("our-group"));
    ownership.observed("our-group", java.util.List.of("requested-peer"));
    assertTrue("normal refresh retains correlated ownership", ownership.mayRemove("our-group"));
    ownership.observed("incoming-group", java.util.List.of("app-peer"));
    assertTrue("different incoming group clears prior capability", !ownership.mayRemove("incoming-group") && !ownership.mayRemove("our-group"));
    ownership.requested("requested-peer");
    ownership.cancelRequest();
    ownership.observed("late-group", java.util.List.of("requested-peer"));
    assertTrue("canceled request does not authorize deleting a later group", !ownership.mayRemove("late-group"));
    ownership.requested("requested-peer");
    ownership.observed("foreign-group", java.util.List.of("different-peer"));
    assertTrue("formed group must contain the actually requested peer", !ownership.mayRemove("foreign-group"));
    ownership.requested("requested-peer");
    ownership.clear();
    ownership.observed("old-session-group", java.util.List.of("requested-peer"));
    assertTrue("new session does not inherit a pending removal capability", !ownership.mayRemove("old-session-group"));

  }

  private static Map<String, String> validRecord() {
    Map<String, String> records = new HashMap<>();
    records.put("app", "persiantrend");
    records.put("v", "1");
    records.put("id", "a".repeat(64));
    records.put("port", "45871");
    return records;
  }

}
