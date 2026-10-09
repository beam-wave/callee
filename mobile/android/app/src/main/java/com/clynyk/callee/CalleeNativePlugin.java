package com.clynyk.callee;

import android.app.NotificationManager;
import android.content.Context;
import android.content.Intent;
import android.net.Uri;
import android.os.Build;
import android.os.PowerManager;
import android.provider.Settings;

import com.getcapacitor.JSObject;
import com.getcapacitor.Plugin;
import com.getcapacitor.PluginCall;
import com.getcapacitor.PluginMethod;
import com.getcapacitor.annotation.CapacitorPlugin;

/** JS bridge: window.Capacitor.registerPlugin("CalleeNative"). */
@CapacitorPlugin(name = "CalleeNative")
public class CalleeNativePlugin extends Plugin {

    @PluginMethod
    public void setSession(PluginCall call) {
        Context ctx = getContext();
        Session.save(ctx, call.getString("url", "https://clynyk.com"), call.getString("token"),
                call.getString("role"), call.getString("uid"));
        CallService.stop(ctx);   // reconnect with the fresh token
        CallService.start(ctx);
        call.resolve();
    }

    @PluginMethod
    public void clearSession(PluginCall call) {
        Session.clear(getContext());
        CallService.stop(getContext());
        call.resolve();
    }

    @PluginMethod
    public void startCallAudio(PluginCall call) {
        CallAudio.start(getContext(), call.getBoolean("speaker", false));
        CallService.cancelRinging(getContext());
        call.resolve();
    }

    @PluginMethod
    public void setSpeaker(PluginCall call) {
        CallAudio.setSpeaker(getContext(), call.getBoolean("on", false));
        call.resolve();
    }

    @PluginMethod
    public void reapplyAudio(PluginCall call) {
        CallAudio.reapply(getContext());
        call.resolve();
    }

    @PluginMethod
    public void stopCallAudio(PluginCall call) {
        CallAudio.stop(getContext());
        call.resolve();
    }

    /** What the Settings page shows about background calling. */
    @PluginMethod
    public void status(PluginCall call) {
        Context ctx = getContext();
        JSObject r = new JSObject();
        r.put("service", Session.load(ctx) != null);
        PowerManager pm = (PowerManager) ctx.getSystemService(Context.POWER_SERVICE);
        r.put("batteryUnrestricted", pm.isIgnoringBatteryOptimizations(ctx.getPackageName()));
        NotificationManager nm = (NotificationManager) ctx.getSystemService(Context.NOTIFICATION_SERVICE);
        r.put("notifications", Build.VERSION.SDK_INT < 24 || nm.areNotificationsEnabled());
        r.put("fullScreen", Build.VERSION.SDK_INT < 34 || nm.canUseFullScreenIntent());
        call.resolve(r);
    }

    @PluginMethod
    public void openBatterySettings(PluginCall call) {
        Context ctx = getContext();
        Intent i = new Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS, Uri.parse("package:" + ctx.getPackageName()));
        i.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
        try { ctx.startActivity(i); } catch (Exception e) {
            ctx.startActivity(new Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK));
        }
        call.resolve();
    }

    @PluginMethod
    public void openNotificationSettings(PluginCall call) {
        Context ctx = getContext();
        Intent i;
        if (Build.VERSION.SDK_INT >= 34) {
            i = new Intent(Settings.ACTION_MANAGE_APP_USE_FULL_SCREEN_INTENT, Uri.parse("package:" + ctx.getPackageName()));
        } else {
            i = new Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS).putExtra(Settings.EXTRA_APP_PACKAGE, ctx.getPackageName());
        }
        i.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
        ctx.startActivity(i);
        call.resolve();
    }
}
