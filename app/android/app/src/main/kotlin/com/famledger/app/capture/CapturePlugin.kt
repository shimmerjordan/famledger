package com.famledger.app.capture

import android.Manifest
import android.app.Activity
import android.app.NotificationManager
import android.content.ActivityNotFoundException
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import android.util.Log
import com.famledger.app.BuildConfig
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.Executors

/**
 * `com.famledger/capture` MethodChannel 的原生端，主引擎与 headless 引擎各挂一个实例。
 *
 * Dart → Native：isListenerEnabled / openListenerSettings / openAutoStartSettings /
 * getAllowedPackages / setAllowedPackages / getInstalledApps / postTestNotification /
 * headlessReady，外加 notificationPermission / requestNotificationPermission / deviceInfo
 * （设置页的通知权限与 MIUI 判断要用，不另加依赖包）。
 *
 * Native → Dart：主引擎 `onOpenCapture(captureId)`；headless 引擎 `onNotification` /
 * `onAction` / `onModelSync`（见 [HeadlessEngine]）。
 */
class CapturePlugin(
    private val context: Context,
    messenger: BinaryMessenger,
    private val activityProvider: () -> Activity?,
    private val onHeadlessReady: (() -> Unit)? = null,
) : MethodChannel.MethodCallHandler {

    private val channel = MethodChannel(messenger, CHANNEL)
    private val main = Handler(Looper.getMainLooper())
    private val io = Executors.newSingleThreadExecutor()
    private var disposed = false

    init {
        channel.setMethodCallHandler(this)
    }

    fun dispose() {
        disposed = true
        channel.setMethodCallHandler(null)
        io.shutdown()
    }

    // ------------------------------------------------------------ Native → Dart

    /** 调 Dart 一个方法；无论成败都回调一次（失败给 null），并通知引擎「一次调用结束」。 */
    fun invoke(method: String, args: Any?, onResult: (Any?) -> Unit) {
        if (disposed) {
            onResult(null)
            return
        }
        channel.invokeMethod(method, args, object : MethodChannel.Result {
            override fun success(result: Any?) {
                HeadlessEngine.onCallFinished()
                onResult(result)
            }

            override fun error(code: String, message: String?, details: Any?) {
                Log.e(TAG, "$method failed: $code $message $details")
                HeadlessEngine.onCallFinished()
                onResult(null)
            }

            override fun notImplemented() {
                Log.w(TAG, "$method not implemented on Dart side")
                HeadlessEngine.onCallFinished()
                onResult(null)
            }
        })
    }

    /**
     * 点开结果通知：先问 Dart 要不要自己导航（`onOpenCapture` 返回 true 表示已处理），
     * Dart 没接（还没接线、或引擎刚启动）就走 [fallback]（原生直接推路由）。
     */
    fun emitOpenCapture(captureId: String, fallback: () -> Unit) {
        if (disposed) {
            fallback()
            return
        }
        channel.invokeMethod("onOpenCapture", captureId, object : MethodChannel.Result {
            override fun success(result: Any?) {
                if (result != true) fallback()
            }

            override fun error(code: String, message: String?, details: Any?) {
                Log.w(TAG, "onOpenCapture failed: $code $message")
                fallback()
            }

            override fun notImplemented() = fallback()
        })
    }

    // ------------------------------------------------------------ Dart → Native

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
                "isListenerEnabled" -> result.success(CaptureListenerService.isEnabled(context))
                "openListenerSettings" -> {
                    openListenerSettings()
                    result.success(null)
                }
                "openAutoStartSettings" -> result.success(openAutoStartSettings())
                "getAllowedPackages" -> result.success(CapturePrefs.allowedPackages(context).sorted())
                "setAllowedPackages" -> {
                    val list = (call.arguments as? List<*>)?.filterIsInstance<String>() ?: emptyList()
                    CapturePrefs.setAllowedPackages(context, list)
                    result.success(null)
                }
                "getInstalledApps" -> installedApps(result)
                "postTestNotification" -> {
                    if (BuildConfig.DEBUG) {
                        val title = call.argument<String>("title") ?: "测试"
                        val text = call.argument<String>("text") ?: ""
                        ResultNotifier.postTest(context, title, text)
                    }
                    result.success(BuildConfig.DEBUG)
                }
                "headlessReady" -> {
                    onHeadlessReady?.invoke()
                    result.success(null)
                }
                "notificationPermission" -> result.success(notificationPermission())
                "requestNotificationPermission" -> {
                    requestNotificationPermission()
                    result.success(null)
                }
                "deviceInfo" -> result.success(
                    mapOf(
                        "manufacturer" to (Build.MANUFACTURER ?: ""),
                        "brand" to (Build.BRAND ?: ""),
                        "sdkInt" to Build.VERSION.SDK_INT,
                        "debug" to BuildConfig.DEBUG,
                    ),
                )
                else -> result.notImplemented()
            }
        } catch (e: Exception) {
            Log.e(TAG, "${call.method} failed", e)
            result.error("native_error", e.message, null)
        }
    }

    private fun startIntent(intent: Intent): Boolean {
        val activity = activityProvider()
        return try {
            if (activity != null) {
                activity.startActivity(intent)
            } else {
                context.startActivity(intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
            }
            true
        } catch (e: ActivityNotFoundException) {
            false
        } catch (e: SecurityException) {
            // 某些 ROM 的设置页不让第三方直接拉起
            false
        }
    }

    private fun openListenerSettings() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            val detail = Intent(Settings.ACTION_NOTIFICATION_LISTENER_DETAIL_SETTINGS).putExtra(
                Settings.EXTRA_NOTIFICATION_LISTENER_COMPONENT_NAME,
                CaptureListenerService.componentName(context).flattenToString(),
            )
            if (startIntent(detail)) return
        }
        if (!startIntent(Intent(Settings.ACTION_NOTIFICATION_LISTENER_SETTINGS))) {
            startIntent(appDetails())
        }
    }

    /** MIUI 自启动页 → MIUI 省电策略页 → 应用详情。返回实际打开了哪一个。 */
    private fun openAutoStartSettings(): String {
        val pkg = context.packageName
        val candidates = listOf(
            "miui_autostart" to Intent().setComponent(
                ComponentName("com.miui.securitycenter", "com.miui.permcenter.autostart.AutoStartManagementActivity"),
            ),
            "miui_autostart_action" to Intent("miui.intent.action.OP_AUTO_START").addCategory(Intent.CATEGORY_DEFAULT),
            "miui_battery" to Intent().setComponent(
                ComponentName("com.miui.powerkeeper", "com.miui.powerkeeper.ui.HiddenAppsConfigActivity"),
            ).putExtra("package_name", pkg).putExtra("package_label", context.applicationInfo.loadLabel(context.packageManager)),
        )
        for ((name, intent) in candidates) {
            if (startIntent(intent)) return name
        }
        startIntent(appDetails())
        return "app_details"
    }

    private fun appDetails(): Intent = Intent(
        Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
        Uri.parse("package:${context.packageName}"),
    )

    /** 可启动的应用（有 LAUNCHER 入口），后台线程查，主线程回。 */
    private fun installedApps(result: MethodChannel.Result) {
        io.execute {
            val out = try {
                val pm = context.packageManager
                val intent = Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_LAUNCHER)
                val seen = HashSet<String>()
                pm.queryIntentActivities(intent, 0).mapNotNull { info ->
                    val pkg = info.activityInfo?.packageName ?: return@mapNotNull null
                    if (!seen.add(pkg)) return@mapNotNull null
                    mapOf("package" to pkg, "label" to info.loadLabel(pm).toString())
                }.sortedBy { it["label"] }
            } catch (e: Exception) {
                Log.e(TAG, "queryIntentActivities failed", e)
                emptyList()
            }
            main.post { result.success(out) }
        }
    }

    private fun notificationPermission(): String {
        val nm = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            val granted = context.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED
            return if (granted && nm.areNotificationsEnabled()) "granted" else "denied"
        }
        return if (nm.areNotificationsEnabled()) "not_required" else "denied"
    }

    private fun requestNotificationPermission() {
        val activity = activityProvider()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU && activity != null &&
            activity.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED
        ) {
            // 同一个权限被拒两次后，系统不再弹框、直接回拒绝 —— 点「允许」看起来什么都没发生。弹过、而且系统已经不给
            // 「再说明一次」的机会（shouldShowRequestPermissionRationale 为 false）就是弹不出来了，改去通知设置页。
            val asked = CapturePrefs.notificationAsked(context)
            if (!asked || activity.shouldShowRequestPermissionRationale(Manifest.permission.POST_NOTIFICATIONS)) {
                CapturePrefs.markNotificationAsked(context)
                activity.requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), REQUEST_POST_NOTIFICATIONS)
                return
            }
        }
        // 权限有了但通知被整体关掉、被拒绝到系统不再弹框（或拿不到 Activity）：去应用的通知设置
        val intent = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS).putExtra(Settings.EXTRA_APP_PACKAGE, context.packageName)
        } else {
            appDetails()
        }
        if (!startIntent(intent)) startIntent(appDetails())
    }

    companion object {
        const val CHANNEL = "com.famledger/capture"
        const val REQUEST_POST_NOTIFICATIONS = 4101
        private const val TAG = "FamLedgerCapture"
    }
}
