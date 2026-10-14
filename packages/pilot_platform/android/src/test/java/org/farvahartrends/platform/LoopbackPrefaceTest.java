package org.farvahartrends.platform;

import org.junit.Test;
import static org.junit.Assert.*;

import java.io.IOException;
import java.io.InputStream;
import java.net.InetAddress;
import java.net.InetSocketAddress;
import java.net.ServerSocket;
import java.net.Socket;
import java.net.SocketTimeoutException;
import java.security.SecureRandom;
import java.util.Arrays;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.Future;
import java.util.concurrent.TimeUnit;
import java.util.function.LongSupplier;

/** Host JVM checks with real loopback sockets; no Android runtime is used. */
public final class LoopbackPrefaceTest {
  private static final LongSupplier CLOCK = () -> System.nanoTime() / 1_000_000L;
  private final SecureRandom random = new SecureRandom();
  private final ExecutorService pool = Executors.newCachedThreadPool();

  private ServerSocket listener() throws IOException {
    ServerSocket server = new ServerSocket();
    server.bind(new InetSocketAddress(InetAddress.getByName("127.0.0.1"), 0), LoopbackPreface.BACKLOG);
    return server;
  }

  private Socket connect(ServerSocket server, byte[] bytes) throws IOException {
    Socket socket = new Socket();
    socket.connect(new InetSocketAddress(InetAddress.getByName("127.0.0.1"), server.getLocalPort()), 2000);
    if (bytes != null && bytes.length > 0) { socket.getOutputStream().write(bytes); socket.getOutputStream().flush(); }
    return socket;
  }

  private static byte[] concat(byte[] first, byte[] second) {
    byte[] result = Arrays.copyOf(first, first.length + second.length);
    System.arraycopy(second, 0, result, first.length, second.length);
    return result;
  }

  private static boolean closedByPeer(Socket socket) throws IOException {
    socket.setSoTimeout(2000);
    try { return socket.getInputStream().read() < 0; }
    catch (SocketTimeoutException timeout) { return false; }
    catch (IOException reset) { return true; }
  }

  @Test
  public void tokensAndComparison() {
    byte[] token = LoopbackPreface.newToken(random);
    assertTrue(LoopbackPreface.valid(token));
    assertFalse(LoopbackPreface.valid(null));
    assertFalse(LoopbackPreface.valid(new byte[31]));
    assertFalse(LoopbackPreface.valid(new byte[33]));
    assertFalse("tokens are random", Arrays.equals(token, LoopbackPreface.newToken(random)));
    assertTrue(LoopbackPreface.matches(token, token.clone()));
    byte[] flipped = token.clone();
    flipped[31] ^= 1;
    assertFalse(LoopbackPreface.matches(token, flipped));
    assertFalse(LoopbackPreface.matches(token, Arrays.copyOf(token, 31)));
    assertFalse(LoopbackPreface.matches(token, null));
  }

  @Test
  public void successLeavesTlsBytesUnread() throws Exception {
    byte[] token = LoopbackPreface.newToken(random);
    byte[] tls = {0x16, 0x03, 0x01, 0x00, 0x05};
    ServerSocket server = listener();
    Future<Socket> accepted = pool.submit(() -> LoopbackPreface.accept(server, token, CLOCK.getAsLong() + 5000, CLOCK, 1000));
    Socket client = connect(server, concat(token, tls));
    Socket authenticated = accepted.get(5, TimeUnit.SECONDS);
    assertNotNull(authenticated);
    assertTrue("listener closes after a single use", server.isClosed());
    byte[] buffer = new byte[tls.length];
    InputStream input = authenticated.getInputStream();
    int offset = 0;
    while (offset < buffer.length) { int n = input.read(buffer, offset, buffer.length - offset); assertTrue(n > 0); offset += n; }
    assertArrayEquals("bytes after the preface reach the pump intact", tls, buffer);
    client.close(); authenticated.close();
  }

  @Test
  public void wrongBytesThenLegitimateCallerSucceeds() throws Exception {
    byte[] token = LoopbackPreface.newToken(random);
    byte[] wrong = token.clone();
    wrong[0] ^= (byte) 0x80;
    ServerSocket server = listener();
    Future<Socket> accepted = pool.submit(() -> LoopbackPreface.accept(server, token, CLOCK.getAsLong() + 5000, CLOCK, 1000));
    Socket hostile = connect(server, wrong);
    assertTrue("wrong caller is disconnected", closedByPeer(hostile));
    assertFalse("flow keeps listening after a wrong caller", server.isClosed());
    Socket legitimate = connect(server, token);
    Socket authenticated = accepted.get(5, TimeUnit.SECONDS);
    assertEquals(legitimate.getLocalPort(), authenticated.getPort());
    legitimate.close(); authenticated.close(); hostile.close();
  }

  @Test
  public void wrongLengthThenCloseIsRejected() throws Exception {
    byte[] token = LoopbackPreface.newToken(random);
    ServerSocket server = listener();
    Future<Socket> accepted = pool.submit(() -> LoopbackPreface.accept(server, token, CLOCK.getAsLong() + 5000, CLOCK, 1000));
    Socket shortCaller = connect(server, Arrays.copyOf(token, 20));
    shortCaller.shutdownOutput();
    assertTrue("short preface followed by EOF is rejected", closedByPeer(shortCaller));
    assertFalse(server.isClosed());
    Socket empty = connect(server, null);
    empty.close();
    Socket legitimate = connect(server, token);
    assertNotNull(accepted.get(5, TimeUnit.SECONDS));
    legitimate.close(); shortCaller.close();
  }

  @Test
  public void silentCallerTimesOutWithoutConsumingFlow() throws Exception {
    byte[] token = LoopbackPreface.newToken(random);
    ServerSocket server = listener();
    long started = CLOCK.getAsLong();
    Future<Socket> accepted = pool.submit(() -> LoopbackPreface.accept(server, token, started + 6000, CLOCK, 300));
    Socket silent = connect(server, null);
    assertTrue("silent caller is dropped at the read deadline", closedByPeer(silent));
    assertTrue("read deadline is short", CLOCK.getAsLong() - started < 3000);
    Socket legitimate = connect(server, token);
    assertNotNull(accepted.get(5, TimeUnit.SECONDS));
    legitimate.close(); silent.close();
  }

  @Test
  public void flowDeadlineFailsLateCaller() throws Exception {
    byte[] token = LoopbackPreface.newToken(random);
    ServerSocket server = listener();
    int port = server.getLocalPort();
    Future<Socket> accepted = pool.submit(() -> LoopbackPreface.accept(server, token, CLOCK.getAsLong() + 300, CLOCK, 1000));
    try { accepted.get(5, TimeUnit.SECONDS); fail("expired flow must fail"); }
    catch (java.util.concurrent.ExecutionException expected) { assertTrue(expected.getCause() instanceof IOException); }
    assertTrue(server.isClosed());
    Socket late = new Socket();
    try {
      late.connect(new InetSocketAddress(InetAddress.getByName("127.0.0.1"), port), 1000);
      late.getOutputStream().write(token);
      late.getOutputStream().flush();
      assertTrue("late caller is refused or disconnected", closedByPeer(late));
    } catch (IOException refused) { /* Expected: nothing listens any more. */ }
    late.close();
  }

  @Test
  public void attemptsAreBounded() throws Exception {
    byte[] token = LoopbackPreface.newToken(random);
    ServerSocket server = listener();
    Future<Socket> accepted = pool.submit(() -> LoopbackPreface.accept(server, token, CLOCK.getAsLong() + 10000, CLOCK, 1000));
    for (int i = 0; i < LoopbackPreface.MAX_ATTEMPTS; i++) {
      Socket hostile = connect(server, new byte[LoopbackPreface.LENGTH]);
      assertTrue(closedByPeer(hostile));
      hostile.close();
    }
    try { accepted.get(5, TimeUnit.SECONDS); fail("attempt bound must abandon the flow"); }
    catch (java.util.concurrent.ExecutionException expected) { assertTrue(expected.getCause() instanceof IOException); }
    assertTrue("abandoned flow closes its listener", server.isClosed());
  }

  @Test
  public void replayAfterUseIsRefused() throws Exception {
    byte[] token = LoopbackPreface.newToken(random);
    ServerSocket server = listener();
    int port = server.getLocalPort();
    Future<Socket> accepted = pool.submit(() -> LoopbackPreface.accept(server, token, CLOCK.getAsLong() + 5000, CLOCK, 1000));
    Socket first = connect(server, token);
    Socket authenticated = accepted.get(5, TimeUnit.SECONDS);
    assertNotNull(authenticated);
    Socket replay = new Socket();
    try {
      replay.connect(new InetSocketAddress(InetAddress.getByName("127.0.0.1"), port), 1000);
      replay.getOutputStream().write(token);
      replay.getOutputStream().flush();
      assertTrue("replayed token after use never reaches a pump", closedByPeer(replay));
    } catch (IOException refused) { /* Expected: the single-use listener is closed. */ }
    replay.close(); first.close(); authenticated.close();
  }

  @Test
  public void writeRejectsInvalidTokens() throws Exception {
    ServerSocket server = listener();
    Socket client = connect(server, null);
    try { LoopbackPreface.write(client, new byte[7]); fail("short token must not be written"); }
    catch (IOException expected) {}
    byte[] token = LoopbackPreface.newToken(random);
    LoopbackPreface.write(client, token);
    Socket accepted = server.accept();
    assertTrue(LoopbackPreface.read(accepted, token, 1000));
    assertFalse("read requires a positive deadline", LoopbackPreface.read(accepted, token, 0));
    client.close(); accepted.close(); server.close();
  }
}
