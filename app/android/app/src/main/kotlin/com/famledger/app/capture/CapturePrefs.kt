package com.famledger.app.capture

import android.content.Context
import android.content.SharedPreferences
import com.famledger.app.BuildConfig

/**
 * 原生侧的一小块持久状态：允许监听的包名、captureId → 流水 id 的映射（深链兜底）、
 * 上次拉共享模型的时间。监听服务在主线程里同步过滤通知，所以这些必须能不经 Dart 直接读到。
 */
object CapturePrefs {
    private const val FILE = "capture_prefs"
    private const val KEY_ALLOWED = "allowed_packages"
    private const val KEY_TX_PREFIX = "tx:"
    private const val KEY_TX_ORDER = "tx_order"
    private const val KEY_LAST_MODEL_SYNC = "last_model_sync"
    private const val KEY_NOTIFICATION_ASKED = "notification_permission_asked"

    /** `adb shell cmd notification post` 发出的通知来自这个包，仅调试构建放行。 */
    const val SHELL_PACKAGE = "com.android.shell"

    /**
     * 用户没改过时的默认允许列表。**必须与 `lib/capture/source_profiles.dart` 的
     * `kDefaultAllowedPackages` 完全一致**（`test/platform/capture_adapters_test.dart` 会对拍）。
     */
    val DEFAULTS: Set<String> = setOf(
        "com.eg.android.AlipayGphone", // 支付宝
        "com.tencent.mm", // 微信
        "com.unionpay", // 云闪付
        // 短信 App
        "com.miui.mms",
        "com.android.mms",
        "com.google.android.apps.messaging",
        "com.samsung.android.messaging",
        // 银行 App
        "cmb.pb",
        "com.chinamworld.main",
        "com.icbc",
        "com.chinamworld.bocmbci",
        "com.android.bankabc",
        "com.bankcomm.Bankcomm",
        "com.yitong.mbank.psbc",
        "cn.com.spdb.mobilebank.per",
        "com.chinamworld.bocmbci.cmbc",
        "com.pingan.paces.ccms",
    )

    private fun prefs(context: Context): SharedPreferences =
        context.applicationContext.getSharedPreferences(FILE, Context.MODE_PRIVATE)

    fun allowedPackages(context: Context): Set<String> {
        val p = prefs(context)
        if (!p.contains(KEY_ALLOWED)) return DEFAULTS
        // getStringSet 返回的实例不能改，拷一份出去。
        return HashSet(p.getStringSet(KEY_ALLOWED, emptySet()) ?: emptySet())
    }

    fun setAllowedPackages(context: Context, packages: Collection<String>) {
        prefs(context).edit().putStringSet(KEY_ALLOWED, packages.toHashSet()).apply()
    }

    /** 监听服务的过滤：用户列表命中，或调试构建下的 shell 通知。 */
    fun isAllowed(context: Context, packageName: String): Boolean =
        allowedPackages(context).contains(packageName) ||
            (BuildConfig.DEBUG && packageName == SHELL_PACKAGE)

    /**
     * 记住这条捕获对应的服务端流水 id，点通知时不必等 Dart 就能算出目标路由。
     * 只保留最新 [TxIndex.MAX] 条（按插入顺序），被挤掉的连同 `tx:` 键一起删。
     */
    fun rememberTransaction(context: Context, captureId: String, transactionId: String?) {
        val p = prefs(context)
        val (order, evicted) = TxIndex.push(TxIndex.decode(p.getString(KEY_TX_ORDER, null)), captureId)
        val e = p.edit()
        for (old in evicted) e.remove(KEY_TX_PREFIX + old)
        if (transactionId.isNullOrEmpty()) e.remove(KEY_TX_PREFIX + captureId) else e.putString(KEY_TX_PREFIX + captureId, transactionId)
        e.putString(KEY_TX_ORDER, TxIndex.encode(order))
        e.apply()
    }

    fun transactionOf(context: Context, captureId: String): String? =
        prefs(context).getString(KEY_TX_PREFIX + captureId, null)

    fun lastModelSync(context: Context): Long = prefs(context).getLong(KEY_LAST_MODEL_SYNC, 0L)

    fun markModelSync(context: Context, at: Long = System.currentTimeMillis()) {
        prefs(context).edit().putLong(KEY_LAST_MODEL_SYNC, at).apply()
    }

    /** 弹过系统的通知权限框没有（Android 13+）：拒绝两次后系统不再弹，靠它判断该改去通知设置页。 */
    fun notificationAsked(context: Context): Boolean = prefs(context).getBoolean(KEY_NOTIFICATION_ASKED, false)

    fun markNotificationAsked(context: Context) {
        prefs(context).edit().putBoolean(KEY_NOTIFICATION_ASKED, true).apply()
    }
}
