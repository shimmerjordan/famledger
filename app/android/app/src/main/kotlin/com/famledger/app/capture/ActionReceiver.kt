package com.famledger.app.capture

import android.app.RemoteInput
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Handler
import android.os.Looper
import android.util.Log

/** 结果通知上的「正确 / 修改… / 撤销」→ headless 引擎的 `onAction`。 */
class ActionReceiver : BroadcastReceiver() {

    override fun onReceive(context: Context, intent: Intent) {
        val captureId = intent.getStringExtra(ResultNotifier.EXTRA_CAPTURE_ID) ?: return
        val action = when (intent.action) {
            ACTION_CONFIRM -> "confirm"
            ACTION_UNDO -> "undo"
            ACTION_REPLY -> "reply"
            else -> return
        }
        // 空回复也照常送去 Dart：那边会回「没有收到修改内容」并保留三个按钮；
        // 这里若直接 return，RemoteInput 的转圈永远停不下来。
        val text = if (action == "reply") {
            RemoteInput.getResultsFromIntent(intent)?.getCharSequence(ResultNotifier.REMOTE_INPUT_KEY)?.toString()?.trim() ?: ""
        } else {
            null
        }

        Log.i(TAG, "$action on $captureId")
        ResultNotifier.showWorking(context, captureId, action)

        // 引擎可能要冷启动 1–2 秒；goAsync 让系统别在 onReceive 返回后立刻把进程当闲置。
        val pending = goAsync()
        var finished = false
        val finish = {
            if (!finished) {
                finished = true
                try {
                    pending.finish()
                } catch (_: Exception) {
                }
            }
        }
        Handler(Looper.getMainLooper()).postDelayed(finish, 9_000)
        HeadlessEngine.dispatchAction(context.applicationContext, captureId, action, text) { finish() }
    }

    companion object {
        private const val TAG = "FamLedgerAction"
        const val ACTION_CONFIRM = "com.famledger.app.capture.CONFIRM"
        const val ACTION_UNDO = "com.famledger.app.capture.UNDO"
        const val ACTION_REPLY = "com.famledger.app.capture.REPLY"
    }
}
