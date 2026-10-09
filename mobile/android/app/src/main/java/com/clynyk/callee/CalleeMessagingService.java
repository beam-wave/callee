package com.clynyk.callee;

import com.google.firebase.messaging.FirebaseMessagingService;
import com.google.firebase.messaging.RemoteMessage;

import java.util.Map;

/**
 * High-priority FCM data messages from the server. They wake the phone even
 * in deep sleep or after the app was swiped away / killed.
 */
public class CalleeMessagingService extends FirebaseMessagingService {
    @Override
    public void onMessageReceived(RemoteMessage msg) {
        Map<String, String> d = msg.getData();
        String type = d.get("type");
        if ("incoming_call".equals(type)) {
            IncomingCall.show(this, d.get("call_id"), d.get("name"), d.get("label"));
            // FCM high priority lets us (re)start the background connection too.
            try { CallService.start(this); } catch (Exception ignored) {}
        } else if ("call_cancel".equals(type)) {
            IncomingCall.cancel(this, d.get("call_id"));
        }
    }

    @Override
    public void onNewToken(String token) {
        Fcm.send(this, token);
    }
}
