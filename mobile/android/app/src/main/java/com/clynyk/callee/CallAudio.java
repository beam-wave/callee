package com.clynyk.callee;

import android.content.Context;
import android.media.AudioDeviceInfo;
import android.media.AudioManager;
import android.os.Build;
import android.os.Handler;
import android.os.Looper;
import android.os.PowerManager;

import java.util.List;

/**
 * Earpiece / loudspeaker routing for calls.
 *
 * Chromium (WebView) turns the speakerphone on for WebRTC by default, so we put
 * the audio system in communication mode and pick the output device ourselves,
 * re-applying a couple of times because WebView may reassert its own choice
 * once media starts. Headsets (Bluetooth / wired / USB) win over the earpiece.
 */
public final class CallAudio {
    private static boolean active = false;
    private static boolean speaker = false;
    private static PowerManager.WakeLock proximity;

    private CallAudio() {}

    public static synchronized void start(Context ctx, boolean useSpeaker) {
        active = true;
        speaker = useSpeaker;
        AudioManager am = (AudioManager) ctx.getSystemService(Context.AUDIO_SERVICE);
        am.setMode(AudioManager.MODE_IN_COMMUNICATION);
        apply(ctx);
        // WebView may flip routing when the stream actually starts; re-assert.
        Handler h = new Handler(Looper.getMainLooper());
        h.postDelayed(() -> apply(ctx), 800);
        h.postDelayed(() -> apply(ctx), 2500);
    }

    public static synchronized void setSpeaker(Context ctx, boolean useSpeaker) {
        speaker = useSpeaker;
        if (active) apply(ctx);
    }

    public static synchronized void reapply(Context ctx) {
        if (active) apply(ctx);
    }

    public static boolean isSpeaker() { return speaker; }

    public static synchronized void stop(Context ctx) {
        active = false;
        AudioManager am = (AudioManager) ctx.getSystemService(Context.AUDIO_SERVICE);
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            am.clearCommunicationDevice();
        } else {
            am.setSpeakerphoneOn(false);
        }
        am.setMode(AudioManager.MODE_NORMAL);
        releaseProximity();
    }

    private static void apply(Context ctx) {
        AudioManager am = (AudioManager) ctx.getSystemService(Context.AUDIO_SERVICE);
        if (am.getMode() != AudioManager.MODE_IN_COMMUNICATION) am.setMode(AudioManager.MODE_IN_COMMUNICATION);
        boolean headset = false;

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            List<AudioDeviceInfo> devices = am.getAvailableCommunicationDevices();
            AudioDeviceInfo pick = null;
            if (!speaker) {
                pick = find(devices, AudioDeviceInfo.TYPE_BLUETOOTH_SCO, AudioDeviceInfo.TYPE_BLE_HEADSET,
                        AudioDeviceInfo.TYPE_WIRED_HEADSET, AudioDeviceInfo.TYPE_WIRED_HEADPHONES,
                        AudioDeviceInfo.TYPE_USB_HEADSET);
                headset = pick != null;
                if (pick == null) pick = find(devices, AudioDeviceInfo.TYPE_BUILTIN_EARPIECE);
            } else {
                pick = find(devices, AudioDeviceInfo.TYPE_BUILTIN_SPEAKER);
            }
            if (pick != null) am.setCommunicationDevice(pick);
        } else {
            headset = am.isWiredHeadsetOn() || am.isBluetoothScoOn();
            am.setSpeakerphoneOn(speaker);
        }

        // Earpiece: blank the screen when the phone is against the ear.
        if (!speaker && !headset) acquireProximity(ctx); else releaseProximity();
    }

    private static AudioDeviceInfo find(List<AudioDeviceInfo> list, int... types) {
        for (int t : types) for (AudioDeviceInfo d : list) if (d.getType() == t) return d;
        return null;
    }

    private static void acquireProximity(Context ctx) {
        if (proximity != null && proximity.isHeld()) return;
        PowerManager pm = (PowerManager) ctx.getSystemService(Context.POWER_SERVICE);
        if (pm.isWakeLockLevelSupported(PowerManager.PROXIMITY_SCREEN_OFF_WAKE_LOCK)) {
            proximity = pm.newWakeLock(PowerManager.PROXIMITY_SCREEN_OFF_WAKE_LOCK, "callee:proximity");
            proximity.acquire(8 * 60 * 60 * 1000L);
        }
    }

    private static void releaseProximity() {
        if (proximity != null && proximity.isHeld()) proximity.release();
        proximity = null;
    }
}
