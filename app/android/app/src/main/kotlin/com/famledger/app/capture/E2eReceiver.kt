package com.famledger.app.capture

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Handler
import android.os.Looper
import android.util.Log
import com.famledger.app.BuildConfig

/**
 * 仅调试构建（只在 debug 清单里注册）：adb 端到端脚本的入口。
 *
 *   adb shell am broadcast -a com.famledger.app.E2E_LOGIN  -n com.famledger.app/.capture.E2eReceiver \
 *       --es baseUrl http://127.0.0.1:48123 --es username e2e --es password secret
 *   adb shell am broadcast -a com.famledger.app.E2E_ACTION -n com.famledger.app/.capture.E2eReceiver \
 *       --es captureId cap-… --es action reply --es text 宠物
 *   adb shell am broadcast -a com.famledger.app.E2E_NOTIFY -n com.famledger.app/.capture.E2eReceiver \
 *       --es package com.eg.android.AlipayGphone --es title 支付宝 --es text '你有一笔35.00元的支出，来自美团'
 *
 * 结果打在 logcat 的 `FamLedgerE2E` 标签下。
 */
class E2eReceiver : BroadcastReceiver() {

    override fun onReceive(context: Context, intent: Intent) {
        if (!BuildConfig.DEBUG) return
        val app = context.applicationContext
        val pending = goAsync()
        var finished = false
        val done: (Map<*, *>?) -> Unit = { result ->
            if (!finished) {
                finished = true
                Log.i(TAG, "${intent.action}: ${result ?: "(no result)"}")
                try {
                    pending.finish()
                } catch (_: Exception) {
                }
            }
        }
        // 引擎起不来也别让广播一直挂着
        Handler(Looper.getMainLooper()).postDelayed({ done(mapOf("timeout" to true)) }, 9_000)
        when (intent.action) {
            ACTION_LOGIN -> HeadlessEngine.dispatchE2eLogin(
                app,
                mapOf(
                    "baseUrl" to intent.getStringExtra("baseUrl"),
                    "username" to intent.getStringExtra("username"),
                    "password" to intent.getStringExtra("password"),
                ),
                done,
            )
            ACTION_ACTION -> {
                val captureId = intent.getStringExtra("captureId")
                val action = intent.getStringExtra("action")
                if (captureId == null || action == null) {
                    done(mapOf("error" to "captureId/action required"))
                    return
                }
                HeadlessEngine.dispatchAction(app, captureId, action, intent.getStringExtra("text"), done)
            }
            ACTION_NOTIFY -> {
                HeadlessEngine.dispatchNotification(
                    app,
                    mapOf(
                        "id" to "e2e-${System.currentTimeMillis()}",
                        "package" to (intent.getStringExtra("package") ?: "com.eg.android.AlipayGphone"),
                        "title" to (intent.getStringExtra("title") ?: ""),
                        "text" to (intent.getStringExtra("text") ?: ""),
                        "bigText" to (intent.getStringExtra("bigText") ?: ""),
                        "postedAt" to System.currentTimeMillis(),
                    ),
                )
                done(mapOf("queued" to true))
            }
            else -> done(mapOf("error" to "unknown action"))
        }
    }

    companion object {
        private const val TAG = "FamLedgerE2E"
        const val ACTION_LOGIN = "com.famledger.app.E2E_LOGIN"
        const val ACTION_ACTION = "com.famledger.app.E2E_ACTION"
        const val ACTION_NOTIFY = "com.famledger.app.E2E_NOTIFY"
    }
}
