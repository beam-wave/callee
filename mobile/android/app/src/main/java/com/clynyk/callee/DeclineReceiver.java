package com.clynyk.callee;

import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;

import org.json.JSONObject;

/** "Decline" on the ringing notification: tell the server over HTTPS. */
public class DeclineReceiver extends BroadcastReceiver {
    @Override
    public void onReceive(Context ctx, Intent intent) {
        String id = intent.getStringExtra("call_id");
        IncomingCall.cancel(ctx, null);
        if (id == null) return;
        PendingResult pr = goAsync();
        Api.post(ctx, "/api/calls/" + id + "/reject", new JSONObject(), pr::finish);
    }
}
