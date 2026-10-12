package org.persiantrend.platform;

import java.net.InetAddress;
import java.net.UnknownHostException;

/** Standalone JVM checks for Nearby's numeric, actual-subnet boundary. */
public final class LocalWifiRulesTest {
  private static int assertions;
  public static void main(String[] args) throws Exception {
    for (String value : new String[]{"192.168.0.43", "10.0.2.2", "172.18.9.20", "100.64.0.2", "1.1.1.1",
        "2001:db8:1234::2", "fd12:3456:7890::2", "::1"}) {
      check(LocalWifiRules.numericAddress(value) != null, "numeric parsed " + value);
    }
    for (String value : new String[]{"example.com", "localhost", "192.168.1.2.example", "192.168.1", "1.2.3.256",
        "1.2.3.-1", "1.2.3.+4", "01.2.3.4", " 1.2.3.4", "1.2.3.4 ", "", "::ffff:1.2.3.4", "fe80::1%wlan0",
        "2001:db8::zz", "a:b", "1:2:3:4:5:6:7:8:9", null}) {
      boolean rejected = false;
      try { LocalWifiRules.numericAddress(value); } catch (UnknownHostException expected) { rejected = true; }
      check(rejected, "non-numeric/ambiguous address rejected " + value);
    }
    check(link("192.168.0.4", 24, "192.168.0.43"), "same actual Wi-Fi subnet allowed");
    check(!link("192.168.0.4", 24, "192.168.1.43"), "adjacent private subnet rejected");
    check(!link("192.168.0.4", 24, "10.0.2.2"), "different private range rejected");
    check(!link("192.168.0.4", 24, "100.64.0.2"), "carrier-private address rejected");
    check(!link("192.168.0.4", 24, "1.1.1.1"), "public Internet address rejected");
    check(!link("192.168.0.4", 24, "192.168.0.4"), "own endpoint rejected");
    check(!link("192.168.0.4", 24, "192.168.0.0"), "network identifier rejected");
    check(!link("192.168.0.4", 24, "192.168.0.255"), "subnet broadcast rejected");
    check(!link("192.168.0.4", 24, "255.255.255.255"), "global broadcast rejected");
    check(!link("192.168.0.4", 0, "1.1.1.1"), "default route never authorizes an endpoint");
    check(!link("192.168.0.4", 33, "192.168.0.43"), "invalid prefix rejected");
    check(link("10.0.2.15", 24, "10.0.2.2"), "emulator actual on-link gateway allowed");
    check(!link("10.0.2.15", 24, "192.168.0.43"), "PC behind emulator gateway is off-link");
    check(link("192.0.2.10", 24, "192.0.2.11"), "local subnet need not use RFC1918 addressing");
    check(link("172.18.0.2", 16, "172.18.5.7"), "actual broader subnet allowed");
    check(!link("172.18.0.2", 16, "172.19.5.7"), "broader subnet boundary enforced");
    check(link("192.168.1.2", 23, "192.168.0.3"), "non-octet prefix inside allowed");
    check(!link("192.168.1.2", 23, "192.168.2.3"), "non-octet prefix outside rejected");
    check(link("10.0.0.0", 31, "10.0.0.1"), "point-to-point prefix allows peer");
    check(!link("10.0.0.1", 32, "10.0.0.2"), "host prefix never admits neighbors");
    check(!link("127.0.0.2", 8, "127.0.0.3"), "loopback is not Wi-Fi");
    check(!link("169.254.1.2", 16, "169.254.1.3"), "ambiguous link-local IPv4 not admitted");
    check(!link("0.0.0.0", 24, "0.0.0.2"), "wildcard cannot define local subnet");
    check(!link("224.0.0.1", 8, "224.0.0.2"), "multicast cannot define local subnet");
    check(!link("192.168.0.4", 1, "239.255.71.71"), "multicast cannot be a peer");
    check(link("fd12:3456:7890::2", 64, "fd12:3456:7890::3"), "ULA IPv6 same subnet allowed");
    check(!link("fd12:3456:7890::2", 64, "fd12:3456:7891::3"), "ULA IPv6 other subnet rejected");
    check(link("2001:db8:1234::2", 64, "2001:db8:1234::3"), "global IPv6 same local link allowed");
    check(!link("2001:db8:1234::2", 64, "2001:db8:5678::3"), "global IPv6 off-link rejected");
    check(!link("2001:db8:1234::2", 0, "2001:db8:5678::3"), "IPv6 default route rejected");
    check(!link("2001:db8:1234::2", 129, "2001:db8:1234::3"), "invalid IPv6 prefix rejected");
    check(!link("2001:db8:1234::2", 64, "::"), "IPv6 unspecified rejected");
    check(!link("2001:db8:1234::2", 64, "::1"), "IPv6 loopback rejected");
    check(!link("2001:db8:1234::2", 64, "ff02::1"), "IPv6 multicast rejected");
    check(!link("fe80::2", 64, "fe80::3"), "unscoped IPv6 link-local rejected");
    check(!link("192.168.0.4", 24, "fd12:3456:7890::3"), "address families must match");
    check(!link("fd12:3456:7890::2", 64, "192.168.0.4"), "IPv6 cannot authorize IPv4");
    check(!LocalWifiRules.onLink(null, 24, addr("192.168.0.4")), "missing local link rejected");
    check(!LocalWifiRules.onLink(addr("192.168.0.4"), 24, null), "missing peer rejected");
    System.out.println("Local Wi-Fi on-link boundary checks passed (" + assertions + " assertions).");
  }
  private static InetAddress addr(String value) throws Exception { return LocalWifiRules.numericAddress(value); }
  private static boolean link(String local, int prefix, String remote) throws Exception {
    return LocalWifiRules.onLink(addr(local), prefix, addr(remote));
  }
  private static void check(boolean value, String description) {
    assertions++;
    if (!value) throw new AssertionError(description);
  }
}
