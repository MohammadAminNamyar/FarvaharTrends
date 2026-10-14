package org.farvahartrends.platform;

import java.io.ByteArrayOutputStream;
import java.util.Arrays;

/** Bounded framing only. Authentication and encryption remain in Dart TLS. */
public final class BleWire {
  private BleWire() {}
  public static final int HELLO = 1, DATA = 2, READY = 3, CREDIT = 4;
  public static final int MAX_BEACON = 4096, WINDOW = 8192, MAX_VALUE = 512;

  public static byte[] frame(int type, int sequence, byte[] payload) {
    if (type < HELLO || type > CREDIT || payload == null || payload.length > MAX_VALUE - 3) {
      throw new IllegalArgumentException("Invalid BLE frame");
    }
    byte[] value = new byte[payload.length + 3];
    value[0] = (byte) type;
    value[1] = (byte) (sequence >>> 8);
    value[2] = (byte) sequence;
    System.arraycopy(payload, 0, value, 3, payload.length);
    return value;
  }

  public static byte[] hello(byte[] beacon) {
    if (beacon == null || beacon.length == 0 || beacon.length > MAX_BEACON) {
      throw new IllegalArgumentException("Invalid discovery beacon length");
    }
    byte[] value = new byte[beacon.length + 2];
    value[0] = (byte) (beacon.length >>> 8);
    value[1] = (byte) beacon.length;
    System.arraycopy(beacon, 0, value, 2, beacon.length);
    return value;
  }

  public static byte[] number(int amount) {
    if (amount <= 0 || amount > WINDOW) throw new IllegalArgumentException("Invalid BLE credit");
    return new byte[] {(byte) (amount >>> 8), (byte) amount};
  }

  public static int number(byte[] value) {
    if (value.length != 2) throw new IllegalArgumentException("Invalid BLE credit length");
    int amount = ((value[0] & 255) << 8) | (value[1] & 255);
    if (amount <= 0 || amount > WINDOW) throw new IllegalArgumentException("Invalid BLE credit");
    return amount;
  }

  public static final class Decoder {
    private int sequence;
    private boolean complete;
    private final ByteArrayOutputStream hello = new ByteArrayOutputStream();

    public Frame read(byte[] value) {
      if (value == null || value.length < 3 || value.length > MAX_VALUE) {
        throw new IllegalArgumentException("Invalid BLE attribute length");
      }
      int actual = ((value[1] & 255) << 8) | (value[2] & 255);
      if (actual != sequence) throw new IllegalArgumentException("Out-of-order BLE frame");
      sequence = (sequence + 1) & 65535;
      int type = value[0] & 255;
      if (type < HELLO || type > CREDIT) throw new IllegalArgumentException("Unknown BLE frame");
      byte[] payload = Arrays.copyOfRange(value, 3, value.length);
      if (type == HELLO) {
        if (complete || payload.length == 0 || hello.size() + payload.length > MAX_BEACON + 2) {
          throw new IllegalArgumentException("Invalid BLE discovery fragment");
        }
        hello.write(payload, 0, payload.length);
        byte[] bytes = hello.toByteArray();
        if (bytes.length < 2) return new Frame(type, null);
        int length = ((bytes[0] & 255) << 8) | (bytes[1] & 255);
        if (length == 0 || length > MAX_BEACON || bytes.length > length + 2) {
          throw new IllegalArgumentException("Invalid BLE discovery length");
        }
        if (bytes.length < length + 2) return new Frame(type, null);
        complete = true;
        hello.reset();
        return new Frame(type, Arrays.copyOfRange(bytes, 2, bytes.length));
      }
      if (!complete) throw new IllegalArgumentException("BLE data before discovery");
      if (type == DATA && payload.length == 0) throw new IllegalArgumentException("Empty BLE data");
      if (type == READY || type == CREDIT) number(payload);
      return new Frame(type, payload);
    }
  }

  public static final class Frame {
    public final int type;
    /** Null only while assembling the discovery beacon. */
    public final byte[] payload;
    Frame(int type, byte[] payload) { this.type = type; this.payload = payload; }
  }
}
