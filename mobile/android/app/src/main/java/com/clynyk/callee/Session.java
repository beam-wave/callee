package com.clynyk.callee;

import android.content.Context;
import android.content.SharedPreferences;

import java.util.UUID;

/** Logged-in user's socket session, handed over by the web app. */
public final class Session {
    private static final String PREFS = "callee_session";

    public final String url, token, role, uid;

    private Session(String url, String token, String role, String uid) {
        this.url = url; this.token = token; this.role = role; this.uid = uid;
    }

    public static void save(Context ctx, String url, String token, String role, String uid) {
        prefs(ctx).edit().putString("url", url).putString("token", token)
                .putString("role", role).putString("uid", uid).apply();
    }

    public static void clear(Context ctx) {
        prefs(ctx).edit().remove("url").remove("token").remove("role").remove("uid").apply();
    }

    public static Session load(Context ctx) {
        SharedPreferences p = prefs(ctx);
        String token = p.getString("token", null);
        if (token == null) return null;
        return new Session(p.getString("url", "https://clynyk.com"), token, p.getString("role", ""), p.getString("uid", ""));
    }

    /** Stable id for the background connection (distinct from WebView tabs). */
    public static String deviceId(Context ctx) {
        SharedPreferences p = prefs(ctx);
        String id = p.getString("device_id", null);
        if (id == null) {
            id = "native-" + UUID.randomUUID();
            p.edit().putString("device_id", id).apply();
        }
        return id;
    }

    private static SharedPreferences prefs(Context ctx) {
        return ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE);
    }
}
