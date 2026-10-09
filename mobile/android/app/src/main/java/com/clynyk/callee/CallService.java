package com.clynyk.callee;

import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.PendingIntent;
import android.app.Service;
import android.content.Context;
import android.content.Intent;
import android.content.pm.ServiceInfo;
import android.media.AudioAttributes;
import android.media.RingtoneManager;
import android.net.Uri;
import android.os.Build;
import android.os.Handler;
import android.os.IBinder;
import android.os.Looper;
import android.util.Log;

import androidx.core.app.NotificationCompat;
import androidx.core.app.Person;

import org.json.JSONArray;
import org.json.JSONObject;

import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicInteger;

import okhttp3.OkHttpClient;
import okhttp3.Request;
import okhttp3.Response;
import okhttp3.WebSocket;
import okhttp3.WebSocketListener;

/**
 * Keeps the phone reachable for calls while the app is closed.
 *
 * A foreground service ("Ready for calls") holds its own Phoenix channel
 * connection to the server, so the server sees the user online and can ring
 * them. On "call:incoming" it shows a full-screen call notification with a
 * ringtone and Answer / Decline, even on the lock screen. It reconnects with
 * backoff and is restarted after reboot by {@link BootReceiver}.
 */
public class CallService extends Service {
    static final String TAG = "CalleeService";
    static final String CH_SERVICE = "callee_service";
    static final String CH_CALLS = "callee_calls_v1";
    static final int ID_SERVICE = 1;
    static final int ID_CALL = 2;

    public static final String ACTION_DECLINE = "com.clynyk.callee.DECLINE";
    public static final String ACTION_STOP = "com.clynyk.callee.STOP";

    private static CallService instance;

    private final OkHttpClient http = new OkHttpClient.Builder()
            .pingInterval(25, TimeUnit.SECONDS)
            .readTimeout(0, TimeUnit.MILLISECONDS)
            .build();
    private final Handler main = new Handler(Looper.getMainLooper());
    private final AtomicInteger ref = new AtomicInteger(1);
    private WebSocket ws;
    private String topic;
    private int backoff = 2;
    private boolean stopping = false;
    private String ringingCallId;

    public static void start(Context ctx) {
        if (Session.load(ctx) == null) return;
        Intent i = new Intent(ctx, CallService.class);
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) ctx.startForegroundService(i); else ctx.startService(i);
    }

    public static void stop(Context ctx) {
        ctx.stopService(new Intent(ctx, CallService.class));
    }

    /** Called when the app UI comes to the foreground / takes the call. */
    public static void cancelRinging(Context ctx) {
        ((NotificationManager) ctx.getSystemService(NOTIFICATION_SERVICE)).cancel(ID_CALL);
        if (instance != null) instance.ringingCallId = null;
    }

    @Override public IBinder onBind(Intent intent) { return null; }

    @Override
    public void onCreate() {
        super.onCreate();
        instance = this;
        createChannels(this);
    }

    @Override
    public int onStartCommand(Intent intent, int flags, int startId) {
        Notification n = new NotificationCompat.Builder(this, CH_SERVICE)
                .setSmallIcon(R.drawable.ic_stat_call)
                .setContentTitle("Ready for calls")
                .setContentText("Callee will ring when someone calls you.")
                .setOngoing(true)
                .setPriority(NotificationCompat.PRIORITY_MIN)
                .setContentIntent(openApp(this, null, false))
                .build();
        if (Build.VERSION.SDK_INT >= 34) {
            startForeground(ID_SERVICE, n, ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE);
        } else {
            startForeground(ID_SERVICE, n);
        }

        if (intent != null && ACTION_DECLINE.equals(intent.getAction())) {
            String id = intent.getStringExtra("call_id");
            if (id != null) push("call:reject", id);
            cancelRinging(this);
            return START_STICKY;
        }

        stopping = false;
        if (ws == null) connect();
        return START_STICKY;
    }

    @Override
    public void onDestroy() {
        stopping = true;
        instance = null;
        if (ws != null) ws.close(1000, "bye");
        ws = null;
        super.onDestroy();
    }

    // ---------------- Phoenix channel ----------------

    private void connect() {
        Session s = Session.load(this);
        if (s == null) { stopSelf(); return; }
        topic = "user:" + s.role + ":" + s.uid;
        String wsUrl = s.url.replaceFirst("^http", "ws") + "/socket/websocket?vsn=2.0.0"
                + "&token=" + Uri.encode(s.token)
                + "&device_id=" + Uri.encode(Session.deviceId(this));
        Request req = new Request.Builder().url(wsUrl).header("Origin", s.url).build();
        ws = http.newWebSocket(req, new WebSocketListener() {
            @Override public void onOpen(WebSocket socket, Response response) {
                backoff = 2;
                send(socket, "1", topic, "phx_join", new JSONObject());
                main.postDelayed(heartbeat, 30_000);
                Log.i(TAG, "connected " + topic);
            }

            @Override public void onMessage(WebSocket socket, String text) { handle(text); }

            @Override public void onClosed(WebSocket socket, int code, String reason) { reconnect(); }

            @Override public void onFailure(WebSocket socket, Throwable t, Response r) {
                Log.w(TAG, "socket failure: " + t);
                // 403 = token rejected (logged out / expired): stop until the app hands a new one.
                if (r != null && r.code() == 403) { Session.clear(CallService.this); stopSelf(); return; }
                reconnect();
            }
        });
    }

    private final Runnable heartbeat = new Runnable() {
        @Override public void run() {
            if (ws == null) return;
            send(ws, null, "phoenix", "heartbeat", new JSONObject());
            main.postDelayed(this, 30_000);
        }
    };

    private void reconnect() {
        main.removeCallbacks(heartbeat);
        ws = null;
        if (stopping) return;
        int delay = backoff;
        backoff = Math.min(backoff * 2, 60);
        main.postDelayed(this::connect, delay * 1000L);
    }

    private void send(WebSocket socket, String joinRef, String t, String event, JSONObject payload) {
        JSONArray msg = new JSONArray();
        msg.put(joinRef == null ? JSONObject.NULL : joinRef);
        msg.put(String.valueOf(ref.getAndIncrement()));
        msg.put(t);
        msg.put(event);
        msg.put(payload);
        socket.send(msg.toString());
    }

    private void push(String event, String callId) {
        if (ws == null || topic == null) return;
        try {
            send(ws, "1", topic, event, new JSONObject().put("call_id", callId));
        } catch (Exception ignored) {}
    }

    private void handle(String text) {
        try {
            JSONArray m = new JSONArray(text);
            String event = m.getString(3);
            JSONObject p = m.optJSONObject(4);
            if (p == null) return;
            switch (event) {
                case "call:incoming":
                    if (!MainActivity.isVisible()) {
                        JSONObject from = p.optJSONObject("from");
                        String name = from != null ? from.optString("name", "Someone") : "Someone";
                        JSONObject group = p.optJSONObject("group");
                        String label = group != null ? (group.optString("name", "").isEmpty() ? "Group call" : group.optString("name")) : "Audio call";
                        main.post(() -> showIncoming(p.optString("call_id"), name, label));
                    }
                    break;
                case "call:ended":
                case "call:accepted":
                    if (p.optString("call_id").equals(ringingCallId)) main.post(() -> cancelRinging(this));
                    break;
                default:
                    break;
            }
        } catch (Exception e) {
            Log.w(TAG, "bad message " + e);
        }
    }

    // ---------------- Incoming call UI ----------------

    private void showIncoming(String callId, String name, String label) {
        ringingCallId = callId;
        Person caller = new Person.Builder().setName(name).setImportant(true).build();

        Intent decline = new Intent(this, CallService.class).setAction(ACTION_DECLINE).putExtra("call_id", callId);
        PendingIntent declinePi = PendingIntent.getService(this, 2, decline,
                PendingIntent.FLAG_UPDATE_CURRENT | PendingIntent.FLAG_IMMUTABLE);
        PendingIntent answerPi = openApp(this, callId, true);
        PendingIntent fullScreen = openApp(this, callId, false);

        Notification n = new NotificationCompat.Builder(this, CH_CALLS)
                .setSmallIcon(R.drawable.ic_stat_call)
                .setContentTitle(name)
                .setContentText(label)
                .setCategory(NotificationCompat.CATEGORY_CALL)
                .setPriority(NotificationCompat.PRIORITY_MAX)
                .setOngoing(true)
                .setAutoCancel(true)
                .setTimeoutAfter(50_000)
                .setFullScreenIntent(fullScreen, true)
                .setContentIntent(fullScreen)
                .setStyle(NotificationCompat.CallStyle.forIncomingCall(caller, declinePi, answerPi))
                .build();
        n.flags |= Notification.FLAG_INSISTENT; // keep ringing until handled
        ((NotificationManager) getSystemService(NOTIFICATION_SERVICE)).notify(ID_CALL, n);
    }

    static PendingIntent openApp(Context ctx, String callId, boolean answer) {
        Intent i = new Intent(ctx, MainActivity.class)
                .setFlags(Intent.FLAG_ACTIVITY_NEW_TASK | Intent.FLAG_ACTIVITY_SINGLE_TOP | Intent.FLAG_ACTIVITY_CLEAR_TOP);
        if (callId != null) {
            i.putExtra("call_id", callId);
            i.putExtra("answer", answer);
        }
        int code = callId == null ? 0 : (answer ? 1 : 3);
        return PendingIntent.getActivity(ctx, code, i, PendingIntent.FLAG_UPDATE_CURRENT | PendingIntent.FLAG_IMMUTABLE);
    }

    static void createChannels(Context ctx) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return;
        NotificationManager nm = (NotificationManager) ctx.getSystemService(NOTIFICATION_SERVICE);

        NotificationChannel svc = new NotificationChannel(CH_SERVICE, "Background connection", NotificationManager.IMPORTANCE_MIN);
        svc.setDescription("Keeps Callee ready to receive calls");
        svc.setShowBadge(false);
        nm.createNotificationChannel(svc);

        NotificationChannel calls = new NotificationChannel(CH_CALLS, "Incoming calls", NotificationManager.IMPORTANCE_HIGH);
        calls.setDescription("Rings when someone calls you");
        calls.setSound(RingtoneManager.getDefaultUri(RingtoneManager.TYPE_RINGTONE),
                new AudioAttributes.Builder()
                        .setUsage(AudioAttributes.USAGE_NOTIFICATION_RINGTONE)
                        .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                        .build());
        calls.enableVibration(true);
        calls.setVibrationPattern(new long[]{0, 800, 400, 800, 400, 800});
        calls.setLockscreenVisibility(Notification.VISIBILITY_PUBLIC);
        calls.setBypassDnd(false);
        nm.createNotificationChannel(calls);
    }
}
