package com.clynyk.callee;

import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;

/** Restart the background calling service after reboot / app update. */
public class BootReceiver extends BroadcastReceiver {
    @Override
    public void onReceive(Context ctx, Intent intent) {
        String a = intent.getAction();
        if (Intent.ACTION_BOOT_COMPLETED.equals(a) || Intent.ACTION_MY_PACKAGE_REPLACED.equals(a)) {
            CallService.start(ctx);
        }
    }
}
