package org.persiantrend.platform;

import org.junit.Test;
import static org.junit.Assert.*;

import java.net.InetAddress;
import java.net.UnknownHostException;

/** Standalone JVM checks for Nearby's numeric, actual-subnet boundary. */
public final class LocalWifiRulesTest {
  @Test
  public void regressionChecks() throws Exception {
    for (String value : new String[]{"192.168.0.43", "10.0.2.2", "172.18.9.20", "100.64.0.2", "1.1.1.1",
        "2001:db8:1234::2", "fd12:3456:7890::2", "::1"}) {
      assertTrue("numeric parsed " + value, LocalWifiRules.numericAddress(value) != null);
    }
    for (String value : new String[]{"example.com", "localhost", "192.168.1.2.example", "192.168.1", "1.2.3.256",
        "1.2.3.-1", "1.2.3.+4", "01.2.3.4", " 1.2.3.4", "1.2.3.4 ", "", "::ffff:1.2.3.4", "fe80::1%wlan0",
        "2001:db8::zz", "a:b", "1:2:3:4:5:6:7:8:9", null}) {
      boolean rejected = false;
      try { LocalWifiRules.numericAddress(value); } catch (UnknownHostException expected) { rejected = true; }
      assertTrue("non-numeric/ambiguous address rejected " + value, rejected);
    }
    assertTrue("same actual Wi-Fi subnet allowed", link("192.168.0.4", 24, "192.168.0.43"));
    assertTrue("adjacent private subnet rejected", !link("192.168.0.4", 24, "192.168.1.43"));
    assertTrue("different private range rejected", !link("192.168.0.4", 24, "10.0.2.2"));
    assertTrue("carrier-private address rejected", !link("192.168.0.4", 24, "100.64.0.2"));
    assertTrue("public Internet address rejected", !link("192.168.0.4", 24, "1.1.1.1"));
    assertTrue("own endpoint rejected", !link("192.168.0.4", 24, "192.168.0.4"));
    assertTrue("network identifier rejected", !link("192.168.0.4", 24, "192.168.0.0"));
    assertTrue("subnet broadcast rejected", !link("192.168.0.4", 24, "192.168.0.255"));
    assertTrue("global broadcast rejected", !link("192.168.0.4", 24, "255.255.255.255"));
    assertTrue("default route never authorizes an endpoint", !link("192.168.0.4", 0, "1.1.1.1"));
    assertTrue("invalid prefix rejected", !link("192.168.0.4", 33, "192.168.0.43"));
    assertTrue("emulator actual on-link gateway allowed", link("10.0.2.15", 24, "10.0.2.2"));
    assertTrue("PC behind emulator gateway is off-link", !link("10.0.2.15", 24, "192.168.0.43"));
    assertTrue("local subnet need not use RFC1918 addressing", link("192.0.2.10", 24, "192.0.2.11"));
    assertTrue("actual broader subnet allowed", link("172.18.0.2", 16, "172.18.5.7"));
    assertTrue("broader subnet boundary enforced", !link("172.18.0.2", 16, "172.19.5.7"));
    assertTrue("non-octet prefix inside allowed", link("192.168.1.2", 23, "192.168.0.3"));
    assertTrue("non-octet prefix outside rejected", !link("192.168.1.2", 23, "192.168.2.3"));
    assertTrue("point-to-point prefix allows peer", link("10.0.0.0", 31, "10.0.0.1"));
    assertTrue("host prefix never admits neighbors", !link("10.0.0.1", 32, "10.0.0.2"));
    assertTrue("loopback is not Wi-Fi", !link("127.0.0.2", 8, "127.0.0.3"));
    assertTrue("ambiguous link-local IPv4 not admitted", !link("169.254.1.2", 16, "169.254.1.3"));
    assertTrue("wildcard cannot define local subnet", !link("0.0.0.0", 24, "0.0.0.2"));
    assertTrue("multicast cannot define local subnet", !link("224.0.0.1", 8, "224.0.0.2"));
    assertTrue("multicast cannot be a peer", !link("192.168.0.4", 1, "239.255.71.71"));
    assertTrue("ULA IPv6 same subnet allowed", link("fd12:3456:7890::2", 64, "fd12:3456:7890::3"));
    assertTrue("ULA IPv6 other subnet rejected", !link("fd12:3456:7890::2", 64, "fd12:3456:7891::3"));
    assertTrue("global IPv6 same local link allowed", link("2001:db8:1234::2", 64, "2001:db8:1234::3"));
    assertTrue("global IPv6 off-link rejected", !link("2001:db8:1234::2", 64, "2001:db8:5678::3"));
    assertTrue("IPv6 default route rejected", !link("2001:db8:1234::2", 0, "2001:db8:5678::3"));
    assertTrue("invalid IPv6 prefix rejected", !link("2001:db8:1234::2", 129, "2001:db8:1234::3"));
    assertTrue("IPv6 unspecified rejected", !link("2001:db8:1234::2", 64, "::"));
    assertTrue("IPv6 loopback rejected", !link("2001:db8:1234::2", 64, "::1"));
    assertTrue("IPv6 multicast rejected", !link("2001:db8:1234::2", 64, "ff02::1"));
    assertTrue("unscoped IPv6 link-local rejected", !link("fe80::2", 64, "fe80::3"));
    assertTrue("address families must match", !link("192.168.0.4", 24, "fd12:3456:7890::3"));
    assertTrue("IPv6 cannot authorize IPv4", !link("fd12:3456:7890::2", 64, "192.168.0.4"));
    assertTrue("missing local link rejected", !LocalWifiRules.onLink(null, 24, addr("192.168.0.4")));
    assertTrue("missing peer rejected", !LocalWifiRules.onLink(addr("192.168.0.4"), 24, null));

  }
  private static InetAddress addr(String value) throws Exception { return LocalWifiRules.numericAddress(value); }
  private static boolean link(String local, int prefix, String remote) throws Exception {
    return LocalWifiRules.onLink(addr(local), prefix, addr(remote));
  }
}
