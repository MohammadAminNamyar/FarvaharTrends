package org.persiantrend.platform;

import java.net.InetAddress;
import java.net.UnknownHostException;
import java.util.Arrays;

/** Numeric, on-link endpoint rules. Private address ranges are never a trust signal. */
final class LocalWifiRules {
  private LocalWifiRules() {}

  static InetAddress numericAddress(String value) throws UnknownHostException {
    if (value == null || value.isEmpty() || value.length() > 45 || value.contains("%")) {
      throw new UnknownHostException("Numeric unicast address required");
    }
    if (value.contains(":")) {
      if (!value.matches("[0-9a-fA-F:]+")) throw new UnknownHostException("Numeric address required");
      InetAddress address = InetAddress.getByName(value);
      if (address.getAddress().length != 16) throw new UnknownHostException("IPv6 address required");
      return address;
    }
    String[] parts = value.split("\\.", -1);
    if (parts.length != 4) throw new UnknownHostException("IPv4 address required");
    byte[] bytes = new byte[4];
    for (int i = 0; i < 4; i++) {
      if (!parts[i].matches("0|[1-9][0-9]{0,2}")) throw new UnknownHostException("Invalid IPv4 address");
      int part = Integer.parseInt(parts[i]);
      if (part > 255) throw new UnknownHostException("Invalid IPv4 address");
      bytes[i] = (byte) part;
    }
    return InetAddress.getByAddress(bytes);
  }

  static boolean validLocal(InetAddress address, int prefixLength) {
    return address != null && prefixLength > 0 && prefixLength <= address.getAddress().length * 8
        && !address.isAnyLocalAddress() && !address.isLoopbackAddress()
        && !address.isMulticastAddress() && !address.isLinkLocalAddress();
  }

  static boolean onLink(InetAddress local, int prefixLength, InetAddress remote) {
    if (!validLocal(local, prefixLength) || remote == null
        || remote.isAnyLocalAddress() || remote.isLoopbackAddress() || remote.isMulticastAddress()
        || remote.isLinkLocalAddress()) return false;
    byte[] a = local.getAddress(), b = remote.getAddress();
    if (a.length != b.length || Arrays.equals(a, b)) return false;
    if (b.length == 4 && ((b[0] & 255) >= 224 || (b[0] & 255) == 0)) return false;
    int full = prefixLength / 8, bits = prefixLength % 8;
    for (int i = 0; i < full; i++) if (a[i] != b[i]) return false;
    if (bits != 0) {
      int mask = 255 << (8 - bits);
      if ((a[full] & mask) != (b[full] & mask)) return false;
    }
    if (b.length == 4 && prefixLength <= 30) {
      boolean allZero = true, allOne = true;
      for (int bit = prefixLength; bit < 32; bit++) {
        boolean one = (b[bit / 8] & (1 << (7 - bit % 8))) != 0;
        allZero &= !one;
        allOne &= one;
      }
      if (allZero || allOne) return false;
    }
    return true;
  }
}
