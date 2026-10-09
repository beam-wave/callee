package com.clynyk.callee;

import android.content.Context;
import android.util.Log;

import com.google.firebase.FirebaseApp;
import com.google.firebase.messaging.FirebaseMessaging;

import org.json.JSONObject;

/** FCM token registration; a no-op when the app was built without google-services.json. */
public final class Fcm {
    private Fcm() {}

    public static boolean available(Context ctx) {
        try { return !FirebaseApp.getApps(ctx).isEmpty() || FirebaseApp.initializeApp(ctx) != null; }
        catch (Throwable t) { return false; }
    }

    public static void registerCurrent(Context ctx) {
        if (Session.load(ctx) == null || !available(ctx)) return;
        FirebaseMessaging.getInstance().getToken().addOnCompleteListener(t -> {
            if (t.isSuccessful() && t.getResult() != null) send(ctx, t.getResult());
            else Log.w("CalleeFcm", "token failed: " + t.getException());
        });
    }

    public static void send(Context ctx, String token) {
        try {
            Api.post(ctx, "/api/devices", new JSONObject().put("token", token).put("platform", "android"), null);
        } catch (Exception ignored) {}
    }
}
