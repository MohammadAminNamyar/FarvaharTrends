package id.flutter.flutter_background_service;

/** The OS may restart an opted-in session, but may never create new consent. */
final class ServiceStartPolicy {
    static final String EXPLICIT_START = "farvahartrends.explicit_receiving_start";
    static final String POLICY_UPDATE = "farvahartrends.receiving_policy_update";

    static boolean mayStart(boolean explicitlyRequested, boolean restartEnabled,
                            boolean foreground, boolean manuallyStopped) {
        return foreground && !manuallyStopped && (explicitlyRequested || restartEnabled);
    }
}
