package com.clynyk.callee;

import android.Manifest;
import android.content.Intent;
import android.content.pm.PackageManager;
import android.os.Build;
import android.os.Bundle;
import android.view.WindowManager;

import androidx.core.app.ActivityCompat;
import androidx.core.content.ContextCompat;

import com.getcapacitor.BridgeActivity;

public class MainActivity extends BridgeActivity {
    private static volatile boolean visible = false;

    public static boolean isVisible() { return visible; }

    @Override
    public void onCreate(Bundle savedInstanceState) {
        registerPlugin(CalleeNativePlugin.class);
        super.onCreate(savedInstanceState);
        CallService.createChannels(this);
        askPermissions();
        handleCallIntent(getIntent());
        CallService.start(this);
    }

    @Override
    protected void onNewIntent(Intent intent) {
        super.onNewIntent(intent);
        setIntent(intent);
        handleCallIntent(intent);
    }

    @Override
    public void onStop() {
        android.webkit.CookieManager.getInstance().flush();
        super.onStop();
    }

    @Override
    public void onResume() {
        super.onResume();
        visible = true;
        CallService.cancelRinging(this);
        if (Session.load(this) != null) CallService.start(this);
        getWindow().getDecorView().postDelayed(this::checkCallReadiness, 1500);
    }

    private android.app.AlertDialog readinessDialog;

    /**
     * Calls only ring reliably if the app may show full-screen call alerts
     * (Android 14+ asks the user) and isn't battery-restricted. Ask until done.
     */
    private void checkCallReadiness() {
        if (!visible || isFinishing() || Session.load(this) == null) return;
        if (readinessDialog != null && readinessDialog.isShowing()) return;

        android.app.NotificationManager nm = getSystemService(android.app.NotificationManager.class);
        android.os.PowerManager pm = getSystemService(android.os.PowerManager.class);
        boolean fsiOk = Build.VERSION.SDK_INT < 34 || nm.canUseFullScreenIntent();
        boolean notifOk = nm.areNotificationsEnabled();
        boolean batteryOk = pm.isIgnoringBatteryOptimizations(getPackageName());
        if (fsiOk && notifOk && batteryOk) return;

        String what; Intent go;
        if (!notifOk) {
            what = "Allow notifications so Callee can ring when someone calls.";
            go = new Intent(android.provider.Settings.ACTION_APP_NOTIFICATION_SETTINGS)
                    .putExtra(android.provider.Settings.EXTRA_APP_PACKAGE, getPackageName());
        } else if (!fsiOk) {
            what = "Allow full-screen calls so incoming calls show on your screen, even when it's locked.";
            go = new Intent(android.provider.Settings.ACTION_MANAGE_APP_USE_FULL_SCREEN_INTENT,
                    android.net.Uri.parse("package:" + getPackageName()));
        } else {
            what = "Let Callee run in the background (battery: Unrestricted) so calls still ring after your phone has been idle.";
            go = new Intent(android.provider.Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS,
                    android.net.Uri.parse("package:" + getPackageName()));
        }
        final Intent target = go;
        readinessDialog = new android.app.AlertDialog.Builder(this)
                .setTitle("Make sure calls ring")
                .setMessage(what)
                .setPositiveButton("Allow", (d, w) -> {
                    try { startActivity(target); } catch (Exception e) {
                        startActivity(new Intent(android.provider.Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                                android.net.Uri.parse("package:" + getPackageName())));
                    }
                })
                .setNegativeButton("Later", null)
                .show();
    }

    @Override
    public void onPause() {
        visible = false;
        // Persist login cookies now; the process may be killed in the background.
        android.webkit.CookieManager.getInstance().flush();
        super.onPause();
    }

    /** Opened from an incoming-call notification: show over the lock screen and go to the call. */
    private void handleCallIntent(Intent intent) {
        if (intent == null || intent.getStringExtra("call_id") == null) return;
        String callId = intent.getStringExtra("call_id");
        boolean answer = intent.getBooleanExtra("answer", false);
        CallService.cancelRinging(this);

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O_MR1) {
            setShowWhenLocked(true);
            setTurnScreenOn(true);
        } else {
            getWindow().addFlags(WindowManager.LayoutParams.FLAG_SHOW_WHEN_LOCKED | WindowManager.LayoutParams.FLAG_TURN_SCREEN_ON);
        }

        Session s = Session.load(this);
        String base = s != null ? s.url : "https://clynyk.com";
        String url = base + "/?" + (answer ? "answer=" : "call=") + callId;
        if (getBridge() != null && getBridge().getWebView() != null) {
            getBridge().getWebView().post(() -> getBridge().getWebView().loadUrl(url));
        }
    }

    private void askPermissions() {
        java.util.List<String> need = new java.util.ArrayList<>();
        if (ContextCompat.checkSelfPermission(this, Manifest.permission.RECORD_AUDIO) != PackageManager.PERMISSION_GRANTED)
            need.add(Manifest.permission.RECORD_AUDIO);
        if (Build.VERSION.SDK_INT >= 33 &&
                ContextCompat.checkSelfPermission(this, Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED)
            need.add(Manifest.permission.POST_NOTIFICATIONS);
        if (!need.isEmpty()) ActivityCompat.requestPermissions(this, need.toArray(new String[0]), 7);
    }
}
