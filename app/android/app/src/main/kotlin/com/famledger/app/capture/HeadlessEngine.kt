package com.famledger.app.capture

import android.content.Context
import android.os.Handler
import android.os.Looper
import android.util.Log
import com.famledger.app.BuildConfig
import io.flutter.FlutterInjector
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.plugins.GeneratedPluginRegistrant

/**
 * 后台 Flutter 引擎（入口 `captureMain`），单例、懒启动。
 *
 * - 事件先入队，Dart 调 `headlessReady` 后才逐个发出；
 * - 空闲 10 分钟销毁引擎（下一条通知再冷启动，约 1–2 秒）；
 * - 引擎启动前先在后台线程把 FlutterLoader 初始化完，不阻塞主线程。
 *
 * 所有状态只在主线程上碰。
 */
object HeadlessEngine {
    private const val TAG = "FamLedgerHeadless"
    private const val ENTRYPOINT = "captureMain"

    /** 入口所在的库：不指定的话引擎只在 main.dart 的根库里找函数。 */
    private const val ENTRYPOINT_LIBRARY = "package:famledger/capture/headless_main.dart"
    private const val IDLE_TIMEOUT_MS = 10 * 60 * 1000L
    private const val STARTUP_TIMEOUT_MS = 45 * 1000L
    private const val MODEL_SYNC_INTERVAL_MS = 10 * 60 * 1000L

    private val main = Handler(Looper.getMainLooper())
    private var engine: FlutterEngine? = null
    private var plugin: CapturePlugin? = null
    private var ready = false
    private var starting = false
    private var inFlight = 0
    private var lastActivityAt = 0L
    private val queue = ArrayDeque<(CapturePlugin) -> Unit>()

    private val idleTeardown = Runnable { teardownIfIdle() }
    private val startupTimeout = Runnable { onStartupTimeout() }

    // ------------------------------------------------------------ 对外入口

    /** 监听服务抓到的通知 → Dart `onNotification` → 结果通知。 */
    fun dispatchNotification(context: Context, payload: Map<String, Any?>) {
        val app = context.applicationContext
        post(app) { p ->
            p.invoke("onNotification", payload) { result ->
                ResultNotifier.showOutcome(app, result as? Map<*, *>)
            }
        }
    }

    /** 通知动作（正确 / 撤销 / 快捷回复）→ Dart `onAction` → 更新同一条通知。 */
    fun dispatchAction(
        context: Context,
        captureId: String,
        action: String,
        text: String?,
        onDone: ((Map<*, *>?) -> Unit)? = null,
    ) {
        val app = context.applicationContext
        post(app) { p ->
            val args = hashMapOf<String, Any?>("captureId" to captureId, "action" to action)
            if (text != null) args["text"] = text
            p.invoke("onAction", args) { result ->
                val map = result as? Map<*, *>
                ResultNotifier.showActionResult(app, captureId, map)
                onDone?.invoke(map)
            }
        }
    }

    /** 拉一次共享模型（`GET /model`），顺便让 Dart 把待重试的捕获补传。 */
    fun dispatchModelSync(context: Context, onDone: ((Map<*, *>?) -> Unit)? = null) {
        val app = context.applicationContext
        post(app) { p ->
            p.invoke("onModelSync", null) { result ->
                CapturePrefs.markModelSync(app)
                onDone?.invoke(result as? Map<*, *>)
            }
        }
    }

    /** 仅调试：让 Dart 用 SessionRepo 登录并落盘会话（adb 端到端脚本用）。 */
    fun dispatchE2eLogin(context: Context, args: Map<String, Any?>, onDone: (Map<*, *>?) -> Unit) {
        if (!BuildConfig.DEBUG) return
        post(context.applicationContext) { p ->
            p.invoke("onE2eLogin", args) { result -> onDone(result as? Map<*, *>) }
        }
    }

    /** 监听刚连上：把引擎和模型预热好。 */
    fun warmUp(context: Context) = maybeSyncModel(context, force = true)

    /** App 回到前台：最多每 10 分钟拉一次共享模型（spec §6「前台时轮询」）。 */
    fun onAppForeground(context: Context) = maybeSyncModel(context, force = false)

    private fun maybeSyncModel(context: Context, force: Boolean) {
        val app = context.applicationContext
        if (!CaptureListenerService.isEnabled(app)) return
        val since = System.currentTimeMillis() - CapturePrefs.lastModelSync(app)
        if (!force && since < MODEL_SYNC_INTERVAL_MS) return
        dispatchModelSync(app)
    }

    // ------------------------------------------------------------ 引擎生命周期

    private fun post(app: Context, work: (CapturePlugin) -> Unit) {
        main.post {
            queue.addLast(work)
            ensureEngine(app)
            flush()
        }
    }

    private fun ensureEngine(app: Context) {
        if (engine != null || starting) return
        starting = true
        main.postDelayed(startupTimeout, STARTUP_TIMEOUT_MS)
        val loader = FlutterInjector.instance().flutterLoader()
        try {
            if (!loader.initialized()) loader.startInitialization(app)
            // 等待在后台线程进行，回调回到主线程再建引擎。
            loader.ensureInitializationCompleteAsync(app, null, main) { startEngine(app) }
        } catch (e: Exception) {
            Log.e(TAG, "flutter loader init failed", e)
            starting = false
            main.removeCallbacks(startupTimeout)
            queue.clear()
        }
    }

    private fun startEngine(app: Context) {
        if (engine != null) return
        try {
            val loader = FlutterInjector.instance().flutterLoader()
            val e = FlutterEngine(app, null, false)
            GeneratedPluginRegistrant.registerWith(e)
            plugin = CapturePlugin(app, e.dartExecutor.binaryMessenger, activityProvider = { null }) {
                // Dart 调了 headlessReady
                main.post {
                    ready = true
                    main.removeCallbacks(startupTimeout)
                    Log.i(TAG, "headless engine ready")
                    flush()
                }
            }
            engine = e
            e.dartExecutor.executeDartEntrypoint(
                DartExecutor.DartEntrypoint(loader.findAppBundlePath(), ENTRYPOINT_LIBRARY, ENTRYPOINT),
            )
            Log.i(TAG, "headless engine started")
        } catch (ex: Exception) {
            Log.e(TAG, "failed to start headless engine", ex)
            teardown()
        } finally {
            starting = false
        }
    }

    private fun flush() {
        val p = plugin ?: return
        if (!ready) return
        while (queue.isNotEmpty()) {
            val work = queue.removeFirst()
            inFlight++
            lastActivityAt = System.currentTimeMillis()
            try {
                work(p)
            } catch (e: Exception) {
                inFlight--
                Log.e(TAG, "dispatch failed", e)
            }
        }
        scheduleIdle()
    }

    /** CapturePlugin 每收到一次 Dart 的回应就调一下。 */
    internal fun onCallFinished() {
        main.post {
            if (inFlight > 0) inFlight--
            lastActivityAt = System.currentTimeMillis()
            scheduleIdle()
        }
    }

    private fun scheduleIdle() {
        main.removeCallbacks(idleTeardown)
        main.postDelayed(idleTeardown, IDLE_TIMEOUT_MS)
    }

    private fun teardownIfIdle() {
        if (inFlight > 0 || queue.isNotEmpty()) {
            // Dart 那头如果永远不回应（引擎卡死），别让 inFlight 把引擎一直钉在内存里。
            if (System.currentTimeMillis() - lastActivityAt > 2 * IDLE_TIMEOUT_MS) {
                Log.e(TAG, "$inFlight call(s) stuck for over ${2 * IDLE_TIMEOUT_MS / 60000} min, destroying headless engine")
                queue.clear()
                teardown()
                return
            }
            scheduleIdle()
            return
        }
        Log.i(TAG, "idle for ${IDLE_TIMEOUT_MS / 60000} min, destroying headless engine")
        teardown()
    }

    private fun onStartupTimeout() {
        if (ready) return
        Log.e(TAG, "headless engine did not become ready in ${STARTUP_TIMEOUT_MS / 1000}s, dropping ${queue.size} event(s)")
        queue.clear()
        teardown()
    }

    private fun teardown() {
        main.removeCallbacks(idleTeardown)
        main.removeCallbacks(startupTimeout)
        plugin?.dispose()
        plugin = null
        try {
            engine?.destroy()
        } catch (e: Exception) {
            Log.w(TAG, "engine destroy failed", e)
        }
        engine = null
        ready = false
        starting = false
        inFlight = 0
    }
}
