package id.flutter.flutter_background_service;

import org.junit.Test;
import static org.junit.Assert.*;

public class ServiceStartPolicyTest {
    @Test public void stoppedSessionsNeverRestartEvenWithAQueuedExplicitIntent() {
        for (boolean explicit : new boolean[]{false, true}) {
            for (boolean restart : new boolean[]{false, true}) {
                assertFalse(ServiceStartPolicy.mayStart(explicit, restart, true, true));
            }
        }
    }

    @Test public void systemRestartRequiresOptInAndAnActiveForegroundSession() {
        assertTrue(ServiceStartPolicy.mayStart(false, true, true, false));
        assertFalse(ServiceStartPolicy.mayStart(false, false, true, false));
        assertFalse(ServiceStartPolicy.mayStart(false, true, false, false));
    }

    @Test public void explicitStartDoesNotRequireRebootOptIn() {
        assertTrue(ServiceStartPolicy.mayStart(true, false, true, false));
        assertFalse(ServiceStartPolicy.mayStart(true, true, false, false));
    }
}
