package org.persiantrend.platform;

import java.util.HashMap;
import java.util.Map;

/** Standalone JVM checks for admission hints and bounded automatic connection attempts. */
public final class WiFiDirectTransportRulesTest {
  private static int assertions;
  public static void main(String[] args) {
    check(WiFiDirectTransport.isAppService("PersianTrend", "_persiantrend._tcp."), "DNS is case insensitive");
    check(WiFiDirectTransport.isAppService("persiantrend", "_persiantrend._tcp.local."), "Android local suffix");
    check(!WiFiDirectTransport.isAppService("printer", "_persiantrend._tcp"), "other instance rejected");
    check(!WiFiDirectTransport.isAppService("persiantrend", "_http._tcp"), "other service rejected");
    check(!WiFiDirectTransport.isAppService("persiantrend.evil", "_persiantrend._tcp"), "instance prefix rejected");
    check(WiFiDirectTransport.isAppDomain("PersianTrend._persiantrend._tcp.local."), "exact TXT domain accepted");
    check(!WiFiDirectTransport.isAppDomain("persiantrend._persiantrend._tcp.local.evil."), "TXT domain suffix rejected");
    check(!WiFiDirectTransport.isAppDomain(null), "null TXT domain rejected");

    Map<String, String> txt = validRecord();
    check(WiFiDirectTransport.validIdentity(txt) != null, "public fingerprint parsed");
    check(WiFiDirectTransport.validPort(txt) == 45871, "service port parsed");
    txt.put("app", "other");
    check(WiFiDirectTransport.validIdentity(txt) == null, "other app rejected");
    txt = validRecord();
    txt.put("id", "a".repeat(63));
    check(WiFiDirectTransport.validIdentity(txt) == null, "short fingerprint rejected");
    txt = validRecord();
    txt.put("v", "2");
    check(WiFiDirectTransport.validIdentity(txt) == null, "unknown version rejected");
    for (String invalid : new String[]{"0", "65536", "-1", "45871x", " 45871", "99999999999"}) {
      txt = validRecord();
      txt.put("port", invalid);
      check(WiFiDirectTransport.validPort(txt) == 0, "invalid port rejected: " + invalid);
    }
    txt = validRecord();
    for (int i = 0; i < 5; i++) txt.put("extra" + i, "ignored");
    check(WiFiDirectTransport.validIdentity(txt) == null, "overlarge TXT key map rejected");

    WiFiDirectTransport.AttemptBudget budget = new WiFiDirectTransport.AttemptBudget();
    check(budget.record("peer-a", 1000), "first request allowed");
    check(!budget.record("peer-a", 120999), "monotonic cooldown enforced");
    check(!budget.record("peer-a", 0), "backward elapsed value cannot bypass cooldown");
    check(budget.record("peer-a", 121000), "second request allowed after cooldown");
    check(!budget.record("peer-a", 999999), "same peer limited to two requests");
    check(budget.record("peer-b", 122000), "second device allowed");
    check(budget.record("peer-c", 123000), "fourth total request allowed");
    check(!budget.record("peer-d", 999999), "global prompt budget enforced");
    check(budget.remaining() == 0, "no automatic attempts remain");
    budget.clear();
    check(budget.remaining() == 4 && budget.record("peer-a", 1000000), "explicit new activation resets budget");

    WiFiDirectTransport.GroupOwnership ownership = new WiFiDirectTransport.GroupOwnership();
    ownership.observed("existing-group", java.util.List.of("app-peer"));
    check(!ownership.mayRemove("existing-group"), "app discovery hints cannot authorize deleting preexisting group");
    ownership.requested("requested-peer");
    ownership.clearGroup();
    ownership.observed("our-group", java.util.List.of("requested-peer"));
    check(ownership.mayRemove("our-group"), "formed group correlated with our own request can be cleaned up");
    ownership.observed("our-group", java.util.List.of("requested-peer"));
    check(ownership.mayRemove("our-group"), "normal refresh retains correlated ownership");
    ownership.observed("incoming-group", java.util.List.of("app-peer"));
    check(!ownership.mayRemove("incoming-group") && !ownership.mayRemove("our-group"), "different incoming group clears prior capability");
    ownership.requested("requested-peer");
    ownership.cancelRequest();
    ownership.observed("late-group", java.util.List.of("requested-peer"));
    check(!ownership.mayRemove("late-group"), "canceled request does not authorize deleting a later group");
    ownership.requested("requested-peer");
    ownership.observed("foreign-group", java.util.List.of("different-peer"));
    check(!ownership.mayRemove("foreign-group"), "formed group must contain the actually requested peer");
    ownership.requested("requested-peer");
    ownership.clear();
    ownership.observed("old-session-group", java.util.List.of("requested-peer"));
    check(!ownership.mayRemove("old-session-group"), "new session does not inherit a pending removal capability");
    System.out.println("Wi-Fi Direct admission/budget checks passed (" + assertions + " assertions).");
  }

  private static Map<String, String> validRecord() {
    Map<String, String> records = new HashMap<>();
    records.put("app", "persiantrend");
    records.put("v", "1");
    records.put("id", "a".repeat(64));
    records.put("port", "45871");
    return records;
  }

  private static void check(boolean value, String message) {
    assertions++;
    if (!value) throw new AssertionError(message);
  }
}
