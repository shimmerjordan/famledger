package com.famledger.app.capture

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.RemoteInput
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.drawable.Icon
import android.net.Uri
import android.os.Build
import android.util.Log
import com.famledger.app.BuildConfig
import com.famledger.app.MainActivity
import com.famledger.app.R

/**
 * 结果通知：「支付宝 −¥35.00 · 餐饮 → 家庭公共基金」+ 动作「正确 / 修改… / 撤销」。
 * 同一条捕获始终更新同一个通知 id；点击走 `famledger://capture/<captureId>?tx=<流水 id>`。
 */
object ResultNotifier {
    const val CHANNEL_RESULTS = "capture_results"
    const val TEST_CHANNEL = "capture_test"
    const val REMOTE_INPUT_KEY = "reply"
    const val EXTRA_CAPTURE_ID = "captureId"
    private const val TAG = "FamLedgerNotify"
    private const val NOTIFICATION_TAG = "famledger.capture"
    private const val TEST_ID = 7001
    private const val ERROR_KEY = "error"

    fun ensureChannels(context: Context) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val nm = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        val results = NotificationChannel(
            CHANNEL_RESULTS,
            context.getString(R.string.capture_channel_name),
            NotificationManager.IMPORTANCE_DEFAULT,
        ).apply { description = context.getString(R.string.capture_channel_description) }
        nm.createNotificationChannel(results)
        if (BuildConfig.DEBUG) {
            nm.createNotificationChannel(
                NotificationChannel(
                    TEST_CHANNEL,
                    context.getString(R.string.capture_test_channel_name),
                    NotificationManager.IMPORTANCE_DEFAULT,
                ),
            )
        }
    }

    /** Dart `onNotification` 的返回 → 通知。忽略/重复不打扰用户。 */
    fun showOutcome(context: Context, result: Map<*, *>?) {
        if (result == null) {
            Log.w(TAG, "onNotification returned nothing")
            return
        }
        val decision = result["decision"] as? String ?: return
        val captureId = result["captureId"] as? String
        val transactionId = result["transactionId"] as? String
        if (captureId != null) CapturePrefs.rememberTransaction(context, captureId, transactionId)
        Log.i(TAG, "decision=$decision") // 标题里有金额，不进日志
        when (decision) {
            "ignored", "duplicate" -> return
        }
        // 没有 captureId 的都是「出错 / 未登录」这一类：固定同一条通知原地更新，
        // 令牌过期时连续几十条通知不能刷成几十条。
        val key = captureId ?: ERROR_KEY
        notify(
            context,
            key = key,
            title = result["title"] as? String ?: "自动记账",
            body = result["body"] as? String ?: "",
            actions = actionsOf(result),
            captureId = captureId,
            transactionId = transactionId,
        )
    }

    /** Dart `onAction` 的返回 → 更新同一条通知（「已更新：…」「已确认：…」「已撤销」）。 */
    fun showActionResult(context: Context, captureId: String, result: Map<*, *>?) {
        if (result == null) {
            notify(context, captureId, "家账没有响应", "请打开家账检查登录状态后重试", emptyList(), captureId, null)
            return
        }
        val transactionId = result["transactionId"] as? String
        if (transactionId != null) CapturePrefs.rememberTransaction(context, captureId, transactionId)
        notify(
            context,
            key = captureId,
            title = result["title"] as? String ?: "已处理",
            body = result["body"] as? String ?: "",
            actions = actionsOf(result),
            captureId = captureId,
            transactionId = transactionId ?: CapturePrefs.transactionOf(context, captureId),
        )
    }

    /** 用户点了动作、Dart 还在处理：先把通知换成「处理中」，RemoteInput 的转圈才会停。 */
    fun showWorking(context: Context, captureId: String, action: String) {
        val label = when (action) {
            "confirm" -> "正在确认…"
            "undo" -> "正在撤销…"
            else -> "正在应用修改…"
        }
        notify(context, captureId, label, "稍等一下", emptyList(), captureId, CapturePrefs.transactionOf(context, captureId))
    }

    /** 仅调试：从自家 `capture_test` 渠道发一条假支付通知给监听器吃。 */
    fun postTest(context: Context, title: String, text: String) {
        if (!BuildConfig.DEBUG) return
        ensureChannels(context)
        if (!canPost(context)) return
        val builder = builder(context, TEST_CHANNEL)
            .setSmallIcon(R.drawable.ic_stat_capture)
            .setContentTitle(title)
            .setContentText(text)
            .setStyle(Notification.BigTextStyle().bigText(text))
            .setAutoCancel(true)
        manager(context).notify("$NOTIFICATION_TAG.test", TEST_ID, builder.build())
    }

    // ------------------------------------------------------------ 内部

    private fun actionsOf(result: Map<*, *>): List<String> =
        (result["actions"] as? List<*>)?.filterIsInstance<String>() ?: emptyList()

    private fun notify(
        context: Context,
        key: String,
        title: String,
        body: String,
        actions: List<String>,
        captureId: String?,
        transactionId: String?,
    ) {
        ensureChannels(context)
        if (!canPost(context)) {
            Log.w(TAG, "POST_NOTIFICATIONS not granted, dropping notification")
            return
        }
        val id = notificationId(key)
        val builder = builder(context, CHANNEL_RESULTS)
            .setSmallIcon(R.drawable.ic_stat_capture)
            .setContentTitle(title)
            .setContentText(body)
            .setStyle(Notification.BigTextStyle().bigText(body))
            .setOnlyAlertOnce(true)
            .setAutoCancel(true)
            .setCategory(Notification.CATEGORY_STATUS)
            .setContentIntent(contentIntent(context, id, captureId, transactionId))
        if (captureId != null) {
            for (action in actions) {
                when (action) {
                    "confirm" -> builder.addAction(simpleAction(context, id, 1, "正确", ActionReceiver.ACTION_CONFIRM, captureId))
                    "edit", "reply" -> builder.addAction(replyAction(context, id, captureId))
                    "undo" -> builder.addAction(simpleAction(context, id, 3, "撤销", ActionReceiver.ACTION_UNDO, captureId))
                }
            }
        }
        manager(context).notify(NOTIFICATION_TAG, id, builder.build())
    }

    private fun builder(context: Context, channel: String): Notification.Builder =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(context, channel)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(context)
        }

    private fun manager(context: Context): NotificationManager =
        context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager

    fun canPost(context: Context): Boolean {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
            context.checkSelfPermission(android.Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED
        ) {
            return false
        }
        return manager(context).areNotificationsEnabled()
    }

    private fun notificationId(key: String): Int = 10_000 + (key.hashCode() and 0x7FFFFFFF) % 1_000_000

    private fun contentIntent(context: Context, id: Int, captureId: String?, transactionId: String?): PendingIntent {
        val uri = if (captureId == null) {
            Uri.parse("famledger://home")
        } else {
            val b = Uri.parse("famledger://capture/$captureId").buildUpon()
            if (!transactionId.isNullOrEmpty()) b.appendQueryParameter("tx", transactionId)
            b.build()
        }
        val intent = Intent(Intent.ACTION_VIEW, uri)
            .setClass(context, MainActivity::class.java)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
        return PendingIntent.getActivity(context, id * 4, intent, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
    }

    private fun simpleAction(context: Context, id: Int, slot: Int, label: String, action: String, captureId: String): Notification.Action {
        val intent = Intent(context, ActionReceiver::class.java).setAction(action).putExtra(EXTRA_CAPTURE_ID, captureId)
        val pi = PendingIntent.getBroadcast(context, id * 4 + slot, intent, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        return Notification.Action.Builder(Icon.createWithResource(context, R.drawable.ic_stat_capture), label, pi).build()
    }

    /** 「修改…」：RemoteInput 要求 PendingIntent 可变（Android 12+），其余动作一律不可变。 */
    private fun replyAction(context: Context, id: Int, captureId: String): Notification.Action {
        val intent = Intent(context, ActionReceiver::class.java).setAction(ActionReceiver.ACTION_REPLY).putExtra(EXTRA_CAPTURE_ID, captureId)
        val mutable = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) PendingIntent.FLAG_MUTABLE else 0
        val pi = PendingIntent.getBroadcast(context, id * 4 + 2, intent, PendingIntent.FLAG_UPDATE_CURRENT or mutable)
        val remoteInput = RemoteInput.Builder(REMOTE_INPUT_KEY)
            .setLabel("基金名 / 类别名 / 金额 / 备注")
            .build()
        return Notification.Action.Builder(Icon.createWithResource(context, R.drawable.ic_stat_capture), "修改…", pi)
            .addRemoteInput(remoteInput)
            .setAllowGeneratedReplies(false)
            .build()
    }
}
