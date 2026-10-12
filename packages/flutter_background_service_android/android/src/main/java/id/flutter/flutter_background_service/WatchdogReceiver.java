package id.flutter.flutter_background_service;

import static android.content.Context.ALARM_SERVICE;
import static android.os.Build.VERSION.SDK_INT;

import android.app.ActivityManager;
import android.app.AlarmManager;
import android.app.PendingIntent;
import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.os.Build;

import androidx.core.content.ContextCompat;

public class WatchdogReceiver extends BroadcastReceiver {
    private static final int QUEUE_REQUEST_ID = 111;
    private static final String ACTION_RESPAWN = "id.flutter.background_service.RESPAWN";

    public static void enqueue(Context context) {
        enqueue(context, 5000);
    }

    public static void enqueue(Context context, int millis) {
        // PersianTrend pilot: receiving starts explicitly; never schedule restart alarms.
        // Keep remove() available to cancel a pending alarm from an older installation.
    }

    public static void remove(Context context) {
        Intent intent = new Intent(context, WatchdogReceiver.class);
        intent.setAction(ACTION_RESPAWN);

        int flags = PendingIntent.FLAG_CANCEL_CURRENT;
        if (SDK_INT >= Build.VERSION_CODES.S) {
            flags |= PendingIntent.FLAG_MUTABLE;
        }

        PendingIntent pi = PendingIntent.getBroadcast(context, WatchdogReceiver.QUEUE_REQUEST_ID, intent, flags);
        AlarmManager alarmManager = (AlarmManager) context.getSystemService(ALARM_SERVICE);
        alarmManager.cancel(pi);
    }

    @Override
    public void onReceive(Context context, Intent intent) {
        if (intent.getAction().equals(ACTION_RESPAWN)) {
            final Config config = new Config(context);
            boolean isRunning = false;

            ActivityManager manager = (ActivityManager) context.getSystemService(Context.ACTIVITY_SERVICE);
            for (ActivityManager.RunningServiceInfo service : manager.getRunningServices(Integer.MAX_VALUE)) {
                if (BackgroundService.class.getName().equals(service.service.getClassName())) {
                    isRunning = true;
                }
            }

            if (!config.isManuallyStopped() && !isRunning) {
                try {
                    if (config.isForeground()) {
                        ContextCompat.startForegroundService(context, new Intent(context, id.flutter.flutter_background_service.BackgroundService.class));
                    } else {
                        context.getApplicationContext().startService(new Intent(context, id.flutter.flutter_background_service.BackgroundService.class));
                    }}
                catch (Exception e){
                    e.printStackTrace();
                }
            }
        }
    }
}
