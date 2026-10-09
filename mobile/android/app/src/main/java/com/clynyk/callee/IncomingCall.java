package com.clynyk.callee;

import android.app.Notification;
import android.app.NotificationManager;
import android.app.PendingIntent;
import android.content.Context;
import android.content.Intent;

import androidx.core.app.NotificationCompat;
import androidx.core.app.Person;

/**
 * The ringing notification (full-screen + CallStyle). Shared by the socket
 * service and FCM so the same call never rings twice.
 */
public final class IncomingCall {
    static final int ID = 2;
    private static String current;

    private IncomingCall() {}

    public static synchronized void show(Context ctx, String callId, String name, String label) {
        if (callId == null || MainActivity.isVisible()) return;
        boolean again = callId.equals(current);
        current = callId;
        CallService.createChannels(ctx);
        Person caller = new Person.Builder().setName(name == null ? "Someone" : name).setImportant(true).build();

        Intent decline = new Intent(ctx, DeclineReceiver.class).putExtra("call_id", callId);
        PendingIntent declinePi = PendingIntent.getBroadcast(ctx, 2, decline,
                PendingIntent.FLAG_UPDATE_CURRENT | PendingIntent.FLAG_IMMUTABLE);
        PendingIntent answerPi = CallService.openApp(ctx, callId, true);
        PendingIntent fullScreen = CallService.openApp(ctx, callId, false);

        Notification n = new NotificationCompat.Builder(ctx, CallService.CH_CALLS)
                .setSmallIcon(R.drawable.ic_stat_call)
                .setContentTitle(name)
                .setContentText(label == null ? "Audio call" : label)
                .setCategory(NotificationCompat.CATEGORY_CALL)
                .setPriority(NotificationCompat.PRIORITY_MAX)
                .setOngoing(true)
                .setAutoCancel(true)
                .setOnlyAlertOnce(again)
                .setTimeoutAfter(50_000)
                .setFullScreenIntent(fullScreen, true)
                .setContentIntent(fullScreen)
                .setStyle(NotificationCompat.CallStyle.forIncomingCall(caller, declinePi, answerPi))
                .build();
        n.flags |= Notification.FLAG_INSISTENT;
        ((NotificationManager) ctx.getSystemService(Context.NOTIFICATION_SERVICE)).notify(ID, n);
    }

    /** Stop ringing; if callId is given, only when it's the call currently ringing. */
    public static synchronized void cancel(Context ctx, String callId) {
        if (callId != null && current != null && !callId.equals(current)) return;
        current = null;
        ((NotificationManager) ctx.getSystemService(Context.NOTIFICATION_SERVICE)).cancel(ID);
    }

    public static synchronized String ringing() { return current; }
}
