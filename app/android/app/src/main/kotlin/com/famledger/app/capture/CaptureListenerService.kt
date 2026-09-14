package com.famledger.app.capture

import android.app.Notification
import android.content.ComponentName
import android.content.Context
import android.os.Build
import android.provider.Settings
import android.service.notification.NotificationListenerService
import android.service.notification.StatusBarNotification
import android.util.Log
import com.famledger.app.BuildConfig

/**
 * 通知监听：只做过滤与抽取，所有解析/分类都交给 headless Flutter 引擎里的 Dart 管线。
 *
 * 过滤顺序：自家包（调试构建放行 `capture_test` 渠道）→ 允许列表 → 分组摘要 →
 * 常驻/前台服务通知 → 空正文。
 */
class CaptureListenerService : NotificationListenerService() {

    override fun onListenerConnected() {
        Log.i(TAG, "listener connected")
        // 顺手把 headless 引擎和共享模型预热好，第一条支付通知就不用等引擎冷启动。
        HeadlessEngine.warmUp(applicationContext)
    }

    override fun onListenerDisconnected() {
        Log.i(TAG, "listener disconnected")
    }

    override fun onNotificationPosted(sbn: StatusBarNotification?) {
        val n = sbn?.notification ?: return
        val pkg = sbn.packageName ?: return

        if (pkg == packageName) {
            // 自家的结果通知绝不能再喂回管线；只有调试用的测试渠道例外。
            val channel = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) n.channelId else null
            if (!(BuildConfig.DEBUG && channel == ResultNotifier.TEST_CHANNEL)) return
        } else if (!CapturePrefs.isAllowed(this, pkg)) {
            return
        }
        if (n.flags and Notification.FLAG_GROUP_SUMMARY != 0) return
        if (sbn.isOngoing || n.flags and Notification.FLAG_FOREGROUND_SERVICE != 0) return

        val extras = n.extras ?: return
        val title = extras.getCharSequence(Notification.EXTRA_TITLE)?.toString()?.trim().orEmpty()
        val text = extras.getCharSequence(Notification.EXTRA_TEXT)?.toString()?.trim().orEmpty()
        val bigText = extras.getCharSequence(Notification.EXTRA_BIG_TEXT)?.toString()?.trim().orEmpty()
        if (text.isEmpty() && bigText.isEmpty()) return

        Log.i(TAG, "notification from $pkg (${text.length}+${bigText.length} chars)")
        HeadlessEngine.dispatchNotification(
            applicationContext,
            mapOf(
                "id" to sbn.key,
                "package" to pkg,
                "title" to title,
                "text" to text,
                "bigText" to bigText,
                "postedAt" to sbn.postTime,
            ),
        )
    }

    companion object {
        private const val TAG = "FamLedgerListener"

        fun componentName(context: Context): ComponentName =
            ComponentName(context, CaptureListenerService::class.java)

        /** 用户是否已在「通知使用权」里放行了我们。 */
        fun isEnabled(context: Context): Boolean {
            val flat = Settings.Secure.getString(
                context.contentResolver,
                "enabled_notification_listeners",
            ) ?: return false
            val cn = componentName(context)
            return flat.split(':').any {
                it == cn.flattenToString() || it == cn.flattenToShortString()
            }
        }
    }
}
