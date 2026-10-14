package org.persiantrend.platform;

import java.io.Closeable;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.net.ServerSocket;
import java.net.Socket;
import java.net.SocketTimeoutException;
import java.security.SecureRandom;
import java.util.function.LongSupplier;

/**
 * A 127.0.0.1 listener is reachable by every app on the device, so loopback
 * alone is not an application identity. Each loopback flow is therefore
 * guarded by a 32-byte random preface that only ever crosses the private
 * Flutter platform channel between native code and the Dart engine of this
 * process. The connecting side writes the exact preface before any TLS byte;
 * the listening side reads exactly that many bytes under a short deadline,
 * compares in constant time and keeps listening for the legitimate caller
 * after a wrong one. Prefaces are never logged, reported or sent on the air.
 */
final class LoopbackPreface {
  static final int LENGTH = 32;
  static final int MAX_ATTEMPTS = 8;
  static final int READ_TIMEOUT_MS = 3000;
  static final int BACKLOG = 4;

  private LoopbackPreface() {}

  static byte[] newToken(SecureRandom random) {
    byte[] token = new byte[LENGTH];
    random.nextBytes(token);
    return token;
  }

  static boolean valid(byte[] token) { return token != null && token.length == LENGTH; }

  /** Constant-time comparison; length differences fail without early exit on content. */
  static boolean matches(byte[] expected, byte[] actual) {
    if (expected == null || actual == null || expected.length != actual.length) return false;
    int difference = 0;
    for (int i = 0; i < expected.length; i++) difference |= expected[i] ^ actual[i];
    return difference == 0;
  }

  /**
   * Accepts loopback callers on {@code server} until one proves the preface,
   * the flow deadline (monotonic milliseconds from {@code clock}) passes, or
   * {@link #MAX_ATTEMPTS} callers failed. A wrong caller never consumes the
   * flow; the authenticated socket is single-use because the listener is
   * always closed before this method returns.
   */
  static Socket accept(ServerSocket server, byte[] token, long deadlineMs, LongSupplier clock)
      throws IOException {
    return accept(server, token, deadlineMs, clock, READ_TIMEOUT_MS);
  }

  static Socket accept(ServerSocket server, byte[] token, long deadlineMs, LongSupplier clock,
      int readTimeoutMs) throws IOException {
    if (!valid(token)) throw new IOException("Invalid loopback preface");
    int attempts = 0;
    try {
      while (true) {
        long remaining = deadlineMs - clock.getAsLong();
        if (remaining <= 0) throw new SocketTimeoutException("Loopback flow expired");
        server.setSoTimeout((int) Math.min(remaining, Integer.MAX_VALUE));
        Socket socket = server.accept();
        boolean authenticated = false;
        try {
          remaining = deadlineMs - clock.getAsLong();
          if (socket.getInetAddress() != null && socket.getInetAddress().isLoopbackAddress()
              && remaining > 0) {
            authenticated = read(socket, token, (int) Math.min(readTimeoutMs, remaining));
          }
        } finally {
          if (!authenticated) close(socket);
        }
        if (authenticated) return socket;
        if (++attempts >= MAX_ATTEMPTS) throw new IOException("Loopback preface attempts exhausted");
      }
    } finally {
      close(server);
    }
  }

  /**
   * Reads exactly {@link #LENGTH} bytes within {@code timeoutMs} and compares
   * them with {@code token}. Bytes after the preface stay unread in the socket
   * for the TLS pump. Returns false on short reads, timeouts or mismatches.
   */
  static boolean read(Socket socket, byte[] token, int timeoutMs) {
    if (!valid(token) || timeoutMs <= 0) return false;
    try {
      int previous = socket.getSoTimeout();
      socket.setSoTimeout(timeoutMs);
      InputStream input = socket.getInputStream();
      byte[] received = new byte[LENGTH];
      int offset = 0;
      while (offset < LENGTH) {
        int count = input.read(received, offset, LENGTH - offset);
        if (count < 0) return false;
        offset += count;
      }
      socket.setSoTimeout(previous);
      return matches(token, received);
    } catch (IOException error) {
      return false;
    }
  }

  /** Writes the preface before any TLS byte on a freshly connected loopback socket. */
  static void write(Socket socket, byte[] token) throws IOException {
    if (!valid(token)) throw new IOException("Invalid loopback preface");
    OutputStream output = socket.getOutputStream();
    output.write(token);
    output.flush();
  }

  static void close(Closeable value) {
    if (value != null) try { value.close(); } catch (IOException ignored) {}
  }
}
