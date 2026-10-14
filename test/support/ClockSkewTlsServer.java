import java.io.BufferedReader;
import java.io.ByteArrayInputStream;
import java.io.InputStreamReader;
import java.nio.charset.StandardCharsets;
import java.security.KeyFactory;
import java.security.KeyStore;
import java.security.SecureRandom;
import java.security.cert.CertificateException;
import java.security.cert.CertificateFactory;
import java.security.cert.X509Certificate;
import java.security.spec.PKCS8EncodedKeySpec;
import java.util.Arrays;
import java.util.Base64;
import java.util.Date;
import javax.net.ssl.*;

/** Isolated real mTLS server with an injected certificate-validation clock.
 * Test keys arrive through stdin, stay in memory, and are never printed/saved.
 */
public class ClockSkewTlsServer {
  private static X509Certificate certificate(String line) throws Exception {
    return (X509Certificate) CertificateFactory.getInstance("X.509")
      .generateCertificate(new ByteArrayInputStream(Base64.getDecoder().decode(line)));
  }
  public static void main(String[] args) throws Exception {
    BufferedReader input = new BufferedReader(new InputStreamReader(System.in, StandardCharsets.US_ASCII));
    X509Certificate serverCert = certificate(input.readLine());
    byte[] keyBytes = Base64.getDecoder().decode(input.readLine());
    X509Certificate expectedClient = certificate(input.readLine());
    Date serverClock = new Date(Long.parseLong(input.readLine()));
    KeyStore keys = KeyStore.getInstance(KeyStore.getDefaultType());
    keys.load(null, null);
    char[] password = new char[0];
    keys.setKeyEntry("test", KeyFactory.getInstance("RSA").generatePrivate(new PKCS8EncodedKeySpec(keyBytes)), password,
      new java.security.cert.Certificate[]{serverCert});
    Arrays.fill(keyBytes, (byte) 0);
    KeyManagerFactory manager = KeyManagerFactory.getInstance(KeyManagerFactory.getDefaultAlgorithm());
    manager.init(keys, password);
    X509TrustManager trust = new X509TrustManager() {
      public X509Certificate[] getAcceptedIssuers() { return new X509Certificate[0]; }
      public void checkServerTrusted(X509Certificate[] chain, String type) throws CertificateException {
        throw new CertificateException("This test context is server-only");
      }
      public void checkClientTrusted(X509Certificate[] chain, String type) throws CertificateException {
        try {
          if (chain.length != 1 || !Arrays.equals(chain[0].getEncoded(), expectedClient.getEncoded()))
            throw new CertificateException("Unpinned test peer");
          chain[0].checkValidity(serverClock);
          chain[0].verify(expectedClient.getPublicKey());
        } catch (CertificateException ex) { throw ex; }
        catch (Exception ex) { throw new CertificateException("Invalid test certificate", ex); }
      }
    };
    SSLContext context = SSLContext.getInstance("TLS");
    context.init(manager.getKeyManagers(), new TrustManager[]{trust}, new SecureRandom());
    try (SSLServerSocket listener = (SSLServerSocket) context.getServerSocketFactory()
        .createServerSocket(0, 1, java.net.InetAddress.getLoopbackAddress())) {
      listener.setSoTimeout(15000);
      listener.setEnabledProtocols(new String[]{"TLSv1.3"});
      listener.setNeedClientAuth(true);
      System.out.println(listener.getLocalPort());
      System.out.flush();
      try (SSLSocket peer = (SSLSocket) listener.accept()) {
        peer.setSoTimeout(15000);
        peer.startHandshake();
        peer.getOutputStream().write("CLOCK_SKEW_ACCEPTED\n".getBytes(StandardCharsets.US_ASCII));
        peer.getOutputStream().flush();
      }
    }
  }
}
