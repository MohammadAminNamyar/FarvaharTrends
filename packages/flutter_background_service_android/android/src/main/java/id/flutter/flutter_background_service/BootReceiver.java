package id.flutter.flutter_background_service;

import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.util.Log;

import androidx.core.content.ContextCompat;

/**
 * FarvaharTrends patch: boot/update restart is opt-in. The receiver acts only
 * when the persisted {@code auto_start_on_boot} preference is true, the
 * service is configured as a foreground service and the participant has not
 * explicitly stopped receiving. It never touches the shared wake lock; the
 * service owns its single acquisition (see PATCH-NOTES.md).
 */
public class BootReceiver extends BroadcastReceiver {
    private static final String TAG = "BootReceiver";

    @Override
    public void onReceive(Context context, Intent intent) {
        if (context == null || intent == null || !isRestartAction(intent.getAction())) return;
        final Config config = new Config(context.getApplicationContext());
        if (!shouldStart(config)) return;
        try {
            // A connectedDevice foreground service may be started from these
            // broadcasts; Android 14/15 only restrict other service types here.
            ContextCompat.startForegroundService(context.getApplicationContext(),
                    new Intent(context.getApplicationContext(), BackgroundService.class));
        } catch (RuntimeException e) {
            // ForegroundServiceStartNotAllowedException and OEM variants: fail
            // soft, the participant can reopen the app and start explicitly.
            Log.w(TAG, "Boot restart refused: " + e.getClass().getSimpleName());
        }
    }

    static boolean isRestartAction(String action) {
        return Intent.ACTION_BOOT_COMPLETED.equals(action)
                || Intent.ACTION_MY_PACKAGE_REPLACED.equals(action);
    }

    /** Opt-in, foreground-only, and never after an explicit Stop. */
    static boolean shouldStart(Config config) {
        return ServiceStartPolicy.mayStart(false, config.isAutoStartOnBoot(),
                config.isForeground(), config.isManuallyStopped());
    }
}
