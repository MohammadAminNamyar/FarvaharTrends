package org.farvahartrends.platform;

import java.util.LinkedHashMap;
import java.util.Map;

/** In-memory ingress admission before TLS proxying; source addresses never leave this table. */
final class LocalWifiIngressBudget {
  static final int PER_SOURCE = 16, GLOBAL = 64, MAX_SOURCES = 128;
  static final int MAX_INCOMING = 4, MAX_TOTAL = 8;
  static final long WINDOW_MS = 60000;
  private final Map<String, Integer> sources = new LinkedHashMap<>();
  private long windowStart = -1;
  private int admitted;

  boolean allow(String source, long now, int incoming, int total) {
    if (source == null || source.isEmpty() || source.length() > 64 || now < 0
        || incoming < 0 || total < 0 || incoming >= MAX_INCOMING || total >= MAX_TOTAL) return false;
    if (windowStart < 0 || now < windowStart || now - windowStart >= WINDOW_MS) {
      sources.clear();
      admitted = 0;
      windowStart = now;
    }
    int count = sources.getOrDefault(source, 0);
    if (count >= PER_SOURCE || admitted >= GLOBAL
        || (count == 0 && sources.size() >= MAX_SOURCES)) return false;
    sources.put(source, count + 1);
    admitted++;
    return true;
  }

  void reset() {
    sources.clear();
    admitted = 0;
    windowStart = -1;
  }

  int trackedSources() { return sources.size(); }
}
