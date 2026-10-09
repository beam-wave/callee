package com.clynyk.callee;

import android.content.Context;
import android.util.Log;

import org.json.JSONObject;

import java.io.IOException;

import okhttp3.Call;
import okhttp3.Callback;
import okhttp3.MediaType;
import okhttp3.OkHttpClient;
import okhttp3.Request;
import okhttp3.RequestBody;
import okhttp3.Response;

/** Small HTTPS client for /api, authenticated with the session's socket token. */
public final class Api {
    private static final OkHttpClient http = new OkHttpClient();
    private static final MediaType JSON = MediaType.get("application/json");

    private Api() {}

    public static void post(Context ctx, String path, JSONObject body, Runnable done) {
        Session s = Session.load(ctx);
        if (s == null) { if (done != null) done.run(); return; }
        Request req = new Request.Builder()
                .url(s.url + path)
                .header("Authorization", "Bearer " + s.token)
                .post(RequestBody.create(body.toString(), JSON))
                .build();
        http.newCall(req).enqueue(new Callback() {
            @Override public void onFailure(Call call, IOException e) {
                Log.w("CalleeApi", path + " failed: " + e);
                if (done != null) done.run();
            }
            @Override public void onResponse(Call call, Response r) {
                Log.i("CalleeApi", path + " -> " + r.code());
                r.close();
                if (done != null) done.run();
            }
        });
    }
}
