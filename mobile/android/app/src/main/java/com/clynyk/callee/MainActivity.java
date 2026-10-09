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
