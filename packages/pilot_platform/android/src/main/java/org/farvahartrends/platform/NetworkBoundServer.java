package org.farvahartrends.platform;

import android.net.Network;
import android.os.Build;
import android.system.ErrnoException;
import android.system.Os;
import android.system.OsConstants;
import android.system.StructTimeval;
import android.util.Log;
import java.io.FileDescriptor;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.net.Inet4Address;
import java.net.InetAddress;
import java.net.InetSocketAddress;
import java.net.ServerSocket;
import java.net.Socket;
import java.net.SocketException;

/** Public Android APIs expose a bindable descriptor before listen(2). */
final class NetworkBoundServer extends ServerSocket {
  private final FileDescriptor descriptor;
  private volatile boolean closed;

  NetworkBoundServer(Network network, InetAddress source, int port) throws IOException {
    if (network == null) throw new IOException("A real Wi-Fi Network is required");
    FileDescriptor candidate = null;
    String operation = "socket";
    try {
      candidate = Os.socket(source instanceof Inet4Address ? OsConstants.AF_INET : OsConstants.AF_INET6,
          OsConstants.SOCK_STREAM, 0);
      Os.setsockoptInt(candidate, OsConstants.SOL_SOCKET, OsConstants.SO_REUSEADDR, 1);
      operation = "network_mark";
      network.bindSocket(candidate);
      operation = "bind";
      Os.bind(candidate, source, port);
      operation = "listen";
      Os.listen(candidate, 8);
      descriptor = candidate;
    } catch (ErrnoException | IOException | RuntimeException error) {
      String value = "listener_" + operation + ":" + error.getClass().getSimpleName();
      if (error instanceof ErrnoException) value += ":errno=" + ((ErrnoException) error).errno;
      Log.w("FarvaharTrendsLocalWifi", value);
      closeDescriptor(candidate);
      throw new IOException("Local Wi-Fi listener could not be bound", error);
    }
  }

  @Override public Socket accept() throws IOException {
    FileDescriptor accepted = null;
    try {
      if (closed) throw new SocketException("Listener closed");
      accepted = Os.accept(descriptor, null);
      if (closed) throw new SocketException("Listener closed");
      return new DescriptorSocket(accepted);
    } catch (ErrnoException | IOException | RuntimeException error) {
      closeDescriptor(accepted);
      throw new IOException("Local Wi-Fi accept failed", error);
    }
  }

  @Override public synchronized void close() {
    if (closed) return;
    closed = true;
    // shutdown wakes a thread blocked in accept before releasing the descriptor.
    try { Os.shutdown(descriptor, OsConstants.SHUT_RDWR); } catch (ErrnoException ignored) {}
    closeDescriptor(descriptor);
  }

  @Override public boolean isClosed() { return closed; }

  private static void closeDescriptor(FileDescriptor value) {
    if (value != null) try { Os.close(value); } catch (ErrnoException ignored) {}
  }

  /** Adapter only for accepted, already Network-bound sockets; no connect path. */
  private static final class DescriptorSocket extends Socket {
    private final FileDescriptor descriptor;
    private final InetAddress source, remote;
    private volatile boolean closed;
    DescriptorSocket(FileDescriptor descriptor) throws ErrnoException {
      this.descriptor = descriptor;
      source = ((InetSocketAddress) Os.getsockname(descriptor)).getAddress();
      remote = ((InetSocketAddress) Os.getpeername(descriptor)).getAddress();
    }
    @Override public InetAddress getLocalAddress() { return source; }
    @Override public InetAddress getInetAddress() { return remote; }
    @Override public boolean isClosed() { return closed; }
    @Override public void setTcpNoDelay(boolean value) throws SocketException {
      try { Os.setsockoptInt(descriptor, OsConstants.IPPROTO_TCP, OsConstants.TCP_NODELAY, value ? 1 : 0); }
      catch (ErrnoException error) { throw new SocketException("TCP option unavailable"); }
    }
    @Override public void setSoTimeout(int millis) throws SocketException {
      // Android 26-28 still use Dart's TLS handshake deadline and bounded flow
      // admission; closing the loopback side tears down the accepted descriptor.
      if (Build.VERSION.SDK_INT < 29) return;
      try {
        Os.setsockoptTimeval(descriptor, OsConstants.SOL_SOCKET, OsConstants.SO_RCVTIMEO,
            StructTimeval.fromMillis(millis));
        Os.setsockoptTimeval(descriptor, OsConstants.SOL_SOCKET, OsConstants.SO_SNDTIMEO,
            StructTimeval.fromMillis(millis));
      } catch (ErrnoException error) { throw new SocketException("Socket timeout unavailable"); }
    }
    @Override public InputStream getInputStream() {
      return new InputStream() {
        @Override public int read() throws IOException {
          byte[] one = new byte[1];
          return read(one, 0, 1) == -1 ? -1 : one[0] & 255;
        }
        @Override public int read(byte[] bytes, int offset, int length) throws IOException {
          if (length == 0) return 0;
          try {
            int count = Os.read(descriptor, bytes, offset, length);
            return count == 0 ? -1 : count;
          } catch (ErrnoException error) { throw new IOException("Local Wi-Fi read failed", error); }
        }
      };
    }
    @Override public OutputStream getOutputStream() {
      return new OutputStream() {
        @Override public void write(int value) throws IOException { write(new byte[]{(byte) value}, 0, 1); }
        @Override public void write(byte[] bytes, int offset, int length) throws IOException {
          try {
            int sent = 0;
            while (sent < length) {
              int count = Os.write(descriptor, bytes, offset + sent, length - sent);
              if (count <= 0) throw new IOException("Local Wi-Fi write made no progress");
              sent += count;
            }
          } catch (ErrnoException error) { throw new IOException("Local Wi-Fi write failed", error); }
        }
      };
    }
    @Override public synchronized void close() {
      if (closed) return;
      closed = true;
      try { Os.shutdown(descriptor, OsConstants.SHUT_RDWR); } catch (ErrnoException ignored) {}
      closeDescriptor(descriptor);
    }
  }
}
