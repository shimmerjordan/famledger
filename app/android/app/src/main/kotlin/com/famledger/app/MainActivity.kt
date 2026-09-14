package com.famledger.app

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.util.Log
import com.famledger.app.capture.CapturePlugin
import com.famledger.app.capture.CapturePrefs
import com.famledger.app.capture.HeadlessEngine
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

/**
 * 主引擎宿主。额外负责：
 * - 挂上主引擎的 [CapturePlugin]（设置页的权限/应用列表等）；
 * - `famledger://` 深链：结果通知点击 `famledger://capture/<captureId>?tx=<流水 id>`
 *   → 先问 Dart（`onOpenCapture`），没人接就原生直接推 `/transactions/<流水 id>`；
 *   冷启动时通过 [getInitialRoute] 给 go_router；
 * - 回到前台时让 headless 引擎（节流地）拉一次共享模型。
 */
class MainActivity : FlutterActivity() {
    private var plugin: CapturePlugin? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        plugin = CapturePlugin(this, flutterEngine.dartExecutor.binaryMessenger, activityProvider = { this })
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        plugin?.dispose()
        plugin = null
        super.cleanUpFlutterEngine(flutterEngine)
    }

    /** 冷启动：深链翻译成 go_router 路径，作为初始路由（go_router 会尊重平台的默认路由）。 */
    override fun getInitialRoute(): String? = DeepLinks.routeFor(this, intent?.data) ?: super.getInitialRoute()

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        handleLink(intent.data)
    }

    override fun onResume() {
        super.onResume()
        HeadlessEngine.onAppForeground(this)
    }

    private fun handleLink(uri: Uri?) {
        val route = DeepLinks.routeFor(this, uri) ?: return
        val engine = flutterEngine ?: return
        val push = { engine.navigationChannel.pushRouteInformation(route) }
        val captureId = DeepLinks.captureIdOf(uri)
        val p = plugin
        if (captureId != null && p != null) {
            p.emitOpenCapture(captureId, fallback = push)
        } else {
            push()
        }
        Log.i(TAG, "deep link $uri → $route")
    }

    companion object {
        private const val TAG = "FamLedgerMain"
    }
}

/** `famledger://` URI ↔ go_router 路径。 */
object DeepLinks {
    const val SCHEME = "famledger"

    fun captureIdOf(uri: Uri?): String? {
        if (uri == null || uri.scheme != SCHEME || uri.host != "capture") return null
        return uri.pathSegments.firstOrNull()?.takeIf { it.isNotEmpty() }
    }

    /**
     * - `famledger://capture/<captureId>[?tx=<id>]` → `/transactions/<id>`（没有流水 id 就回首页看待确认）；
     * - `famledger://settings/capture` → `/settings/capture`（host + path 直译）；
     * - `famledger:///transactions/x`（空 host）→ 原样的 path。
     */
    fun routeFor(context: Context, uri: Uri?): String? {
        if (uri == null || uri.scheme != SCHEME) return null
        val captureId = captureIdOf(uri)
        if (captureId != null) {
            val tx = uri.getQueryParameter("tx")?.takeIf { it.isNotEmpty() }
                ?: CapturePrefs.transactionOf(context, captureId)
            return if (tx != null) "/transactions/$tx" else "/home"
        }
        val host = uri.host.orEmpty()
        val path = uri.path.orEmpty()
        val route = if (host.isEmpty()) path else "/$host$path"
        return route.trimEnd('/').ifEmpty { "/home" }
    }
}
