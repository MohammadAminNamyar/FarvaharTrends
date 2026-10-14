package org.persiantrend.platform;

import org.junit.Test;
import static org.junit.Assert.*;

import java.util.Arrays;

/** Host JVM protocol tests; no Bluetooth hardware or Android framework mocks. */
public final class BleWireTest {
  private static void rejects(Runnable call) {
    assertThrows(IllegalArgumentException.class, call::run);
  }
  @Test
  public void regressionChecks() {
    byte[] beacon = new byte[BleWire.MAX_BEACON];
    for (int i = 0; i < beacon.length; i++) beacon[i] = (byte) (i * 73);
    byte[] hello = BleWire.hello(beacon);
    BleWire.Decoder decoder = new BleWire.Decoder();
    int sequence = 0;
    BleWire.Frame decoded = null;
    // Negotiate nothing: minimum MTU23 still transfers a full 4096-byte beacon.
    for (int offset = 0; offset < hello.length; offset += 17) {
      decoded = decoder.read(BleWire.frame(BleWire.HELLO, sequence++,
          Arrays.copyOfRange(hello, offset, Math.min(hello.length, offset + 17))));
      assertTrue(decoded.payload == null || offset + 17 >= hello.length);
    }
    assertTrue(Arrays.equals(beacon, decoded.payload));
    assertTrue(BleWire.number(decoder.read(BleWire.frame(BleWire.READY, sequence++, BleWire.number(BleWire.WINDOW))).payload) == BleWire.WINDOW);
    assertTrue(Arrays.equals(new byte[] {1, 2, 3}, decoder.read(BleWire.frame(BleWire.DATA, sequence++, new byte[] {1, 2, 3})).payload));
    assertTrue(BleWire.number(decoder.read(BleWire.frame(BleWire.CREDIT, sequence++, BleWire.number(3))).payload) == 3);
    // Sequence wraps without accepting reordering or duplicate discovery.
    while (sequence < 65538) decoder.read(BleWire.frame(BleWire.CREDIT, sequence++, BleWire.number(1)));
    int expected = sequence;
    rejects(() -> decoder.read(BleWire.frame(BleWire.DATA, expected + 1, new byte[] {4})));
    rejects(() -> new BleWire.Decoder().read(BleWire.frame(BleWire.DATA, 0, new byte[] {1})));
    rejects(() -> new BleWire.Decoder().read(BleWire.frame(BleWire.READY, 0, BleWire.number(1))));
    rejects(() -> new BleWire.Decoder().read(BleWire.frame(BleWire.HELLO, 0, new byte[] {16, 1})));
    rejects(() -> new BleWire.Decoder().read(BleWire.frame(BleWire.HELLO, 0, new byte[] {0, 1, 42, 43})));
    rejects(() -> new BleWire.Decoder().read(new byte[513]));
    rejects(() -> BleWire.hello(new byte[4097]));
    rejects(() -> BleWire.hello(new byte[0]));
    rejects(() -> BleWire.frame(BleWire.DATA, 0, new byte[510]));
    rejects(() -> BleWire.number(0));
    rejects(() -> BleWire.number(8193));
    rejects(() -> BleWire.number(new byte[] {0}));
    BleWire.Decoder duplicate = new BleWire.Decoder();
    duplicate.read(BleWire.frame(BleWire.HELLO, 0, BleWire.hello(new byte[] {42})));
    rejects(() -> duplicate.read(BleWire.frame(BleWire.HELLO, 1, BleWire.hello(new byte[] {42}))));

  }
}
