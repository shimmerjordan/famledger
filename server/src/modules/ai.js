'use strict';

// AI 渠道：渠道管理 + 流式对话 + 月报 + 分类兜底。
//
//   GET    /ai/presets              一键填表用的预设清单（静态）
//   GET    /ai/providers            渠道列表（密钥只给 hasKey + 尾 4 位）
//   POST   /ai/providers            新建（admin）
//   PATCH  /ai/providers/:id        改；apiKey 缺省或空串 = 不动密钥（admin）
//   DELETE /ai/providers/:id        删（admin，硬删：渠道不参与同步）
//   POST   /ai/providers/:id/test   一次非流式往返，回 {ok, model, latencyMs, sample}
//          ?vision=1                看图探测：发一张 2×2 的红色 PNG 问颜色，结果写进渠道 extra.vision（true / false；
//                                   判断不了——连不上、401、5xx、没回答、测的时候渠道被改了——不写），
//                                   回 {ok, vision, model, latencyMs, sample, message, provider}；测的时候渠道被删了回 404
//   POST   /ai/chat                 SSE：delta* → done | error
//   POST   /ai/report?month=        SSE 同上，完成后落 ai_reports，done 里带 reportId
//   GET    /ai/reports?month=       月报列表（新的在前）
//   POST   /ai/classify             非流式 + JSON 解析，给自动记账兜底
//
// 三条红线：
//   1. 密钥 AES-GCM 落库，出站响应里只有 hasKey/keyTail，错误消息里也要擦掉；
//   2. 模型永远不直接查库 —— 服务端把聚合数字拼成中文塞进 system（ai_prompts.js）；
//   3. 客户端一断，上游那条 fetch 立刻 abort，不给别人白烧 token。
//
// 两道花钱的闸门（上游是按 token 收费的，这两条都不是性能优化，是账单保护）：
//   · 每人每分钟 AI_PER_MIN 次（默认 30），按 member.id 建桶 —— 家里人都在同一个
//     公网 IP 后面，按 IP 限流会互相挤掉。超了 429 rate_limited。
//   · 同时在跑的上游**流**最多 AI_MAX_STREAMS 条（默认 4），超了 503 ai_busy。
//     名额在 finally 里还，客户端半路跑了也照还。
//
// 这几样挂在 ctx.ai 上给别的模块用（AI 导入，modules/asset_import.js）：
//   ctx.ai = { pickProvider(id, {needVision}), takeToken(reqCtx), toUse(row), friendly(e, apiKey), withStreamSlot(fn) }

const crypto = require('node:crypto');

const { HttpError, sendJson } = require('../lib/router');
const { RateLimiter } = require('../lib/ratelimit');
const { rowToJson } = require('../lib/db');
const { openSse } = require('../lib/sse');
const { encrypt, decrypt } = require('../lib/secret');
const { logActivity } = require('../lib/activity');
const v = require('../lib/validate');
const { judgeVisionAnswer } = require('../lib/vision_probe');

const providers = require('./ai_providers');
const prompts = require('./ai_prompts');
const stats = require('./stats');

const MAX_MESSAGES = 40;
const MAX_MESSAGE_CHARS = 8000;
const CHAT_MAX_BODY = 1024 * 1024; // 40 条 × 8000 字，中文 3 字节 —— 默认 64KB 不够
const CHAT_MAX_TOKENS = 2048;
const REPORT_MAX_TOKENS = 3000;
const CLASSIFY_MAX_TOKENS = 300;
const TEST_MAX_TOKENS = 8;
/** 看图探测的输出上限：答一个颜色词够了，但给带思考的模型留点余量（8 个 token 常常还没开口就用完了）。 */
const VISION_TEST_MAX_TOKENS = 64;
/** 2×2 的纯红 PNG（74 字节）。 */
const VISION_PNG = 'iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAIAAAD91JpzAAAAEUlEQVR4nGP4z8DwnwGMgRQAH+4D/dJQfRoAAAAASUVORK5CYII=';
/** 上游 400 的报文里提到这些词：这个模型不收图片（DeepSeek：unknown variant `image_url`；别的：does not support image input）。 */
const NO_VISION_HINT = /image|vision|multimodal|多模态|图片|图像/i;
/** 改了这几列，看图探测的结果就作废（换了模型，能不能看图得重新测）。 */
const VISION_KEYS = ['kind', 'base_url', 'model'];
const REPORTS_LIMIT = 20;
const MAX_CANDIDATES = 200;

const COLUMNS = 'id, name, kind, base_url, api_key_enc, model, is_default, enabled, extra, created_at, updated_at';

/**
 * 与 server.js 的 envInt 同义：缺失或非法（`abc`、`0`、`3.5`）一律回默认值。
 * 这两个变量没进 cfg 是因为 server.js 归 Task 1，不归我改；语义必须逐字一致，
 * 否则 `AI_PER_MIN=0` 会变成「谁都用不了」而且一声不吭。
 */
function envInt(name, dflt, min = 1) {
  const n = Number(process.env[name]);
  return Number.isFinite(n) && Number.isInteger(n) && n >= min ? n : dflt;
}

module.exports = (ctx) => {
  const { db, secret, log } = ctx;

  const aiPerMin = envInt('AI_PER_MIN', 30);
  const maxStreams = envInt('AI_MAX_STREAMS', 4);
  // 独立的桶：跟登录限流各算各的，一次失败的对话不该吃掉家人的登录额度。
  const limiter = new RateLimiter(aiPerMin);
  /** 正在跑的上游流条数（非流式的 test/classify 不占名额，它们只有一次往返）。 */
  let liveStreams = 0;

  /** 每个花上游钱的入口的第一句话。 */
  function takeToken(reqCtx) {
    if (!limiter.allow(reqCtx.member.id)) {
      log.warn('ai', `成员 ${reqCtx.member.username} 触发限流（${aiPerMin}/min）`);
      throw new HttpError(429, 'rate_limited', `AI 请求太频繁了（每分钟最多 ${aiPerMin} 次），缓一会儿再试`);
    }
  }

  // ------------------------------------------------------------ 行 ↔ JSON

  /** 密钥永远不出这个函数：只报「有没有」和尾 4 位。 */
  function toJson(row) {
    let hasKey = false;
    let keyTail = null;
    if (row.api_key_enc) {
      hasKey = true;
      // 有钥匙但短得藏不住尾巴（< 8 位）→ 空串：宁可什么都不显示，也不能把一把
      // 6 位的密钥当「尾 4 位」整段回显出去。解不开（secret.key 换过）才是 null。
      keyTail = '';
      try {
        const k = decrypt(secret, row.api_key_enc) || '';
        if (k.length >= 8) keyTail = k.slice(-4);
      } catch {
        keyTail = null;
      }
    }
    const json = rowToJson(row, { omit: ['api_key_enc'], bools: ['is_default', 'enabled'], json: ['extra'] });
    return { ...json, hasKey, keyTail };
  }

  /** 行 → 适配器要的 provider（apiKey 已解密；extra 解析成对象，requestExtras / importMaxTokens / vision 都在里面）。 */
  function toUse(row) {
    let apiKey = '';
    if (row.api_key_enc) {
      try {
        apiKey = decrypt(secret, row.api_key_enc) || '';
      } catch (e) {
        log.warn('ai', `渠道 ${row.id} 的密钥解不开（secret.key 换过？）：${e.message}`);
      }
    }
    let extra = {};
    try {
      const parsed = JSON.parse(row.extra || '{}');
      if (v.isObject(parsed)) extra = parsed;
    } catch {
      /* 坏的 extra 当没有：不能因为它让渠道整个用不了 */
    }
    return { id: row.id, kind: row.kind, baseUrl: row.base_url, model: row.model, apiKey, extra };
  }

  const byId = (id) => db.get(`SELECT ${COLUMNS} FROM ai_providers WHERE id = ?`, id);

  const extraOf = (row) => toUse(row).extra;

  /**
   * 明确指定 > 默认且启用 > 第一个启用的。一个都没有就是 400，不是 500。
   * `needVision`（截图导入，P5）：跳过测出来看不了图的渠道（extra.vision === false）；指定的那个看不了图 → 400。
   */
  function pickProvider(providerId, { needVision = false } = {}) {
    if (providerId !== undefined && providerId !== null && providerId !== '') {
      const id = v.str(providerId, 'providerId', { max: 64 });
      const row = byId(id);
      if (!row) throw new HttpError(404, 'not_found', 'AI 渠道不存在');
      if (!row.enabled) throw new HttpError(400, 'provider_disabled', '这个 AI 渠道已停用');
      if (needVision && !providers.visionOk(extraOf(row))) {
        throw new HttpError(400, 'provider_no_vision', '这个 AI 渠道看不了图片，换一个支持看图的渠道');
      }
      return row;
    }
    const rows = db.all(`SELECT ${COLUMNS} FROM ai_providers WHERE enabled = 1 ORDER BY is_default DESC, created_at, id`);
    const row = rows.find((r) => !needVision || providers.visionOk(extraOf(r)));
    if (!row) {
      if (needVision && rows.length) throw new HttpError(400, 'provider_no_vision', '现有的 AI 渠道都看不了图片，先加一个支持看图的渠道');
      throw new HttpError(400, 'no_provider', '还没有可用的 AI 渠道，请先在「设置 → AI 渠道」里添加一个');
    }
    return row;
  }

  /** 给用户看的失败原因，顺手把密钥擦掉（上游 401 的正文有时会回显它）。 */
  function friendly(e, apiKey) {
    let msg;
    if (e instanceof providers.UpstreamError) msg = e.message;
    else if (e && e.name === 'IdleTimeoutError') msg = e.message;
    else if (e && e.name === 'TimeoutError') msg = `上游 ${Math.round(providers.TIMEOUT_MS / 1000)} 秒没有响应`;
    else if (e && e.name === 'AbortError') msg = '请求已取消';
    else msg = (e && e.message ? String(e.message) : '未知错误').slice(0, 300);
    if (apiKey && apiKey.length >= 6) msg = msg.split(apiKey).join('***');
    return msg;
  }

  // ------------------------------------------------------------ 写入校验

  /**
   * body → 列值。`existing` 有值时是 PATCH：没给的字段一律不动。
   * @returns {object} snake_case 列名 → 值
   */
  function readWrite(b, existing) {
    const patch = !!existing;
    const cols = {};

    if (!patch || b.name !== undefined) cols.name = v.str(b.name, 'name', { max: 60 });
    if (!patch || b.kind !== undefined) cols.kind = v.enumOf(b.kind, 'kind', providers.KINDS);
    if (!patch || b.baseUrl !== undefined) {
      const u = providers.normalizeBaseUrl(b.baseUrl);
      if (!u) v.bad('baseUrl', 'baseUrl 必须是 http:// 或 https:// 开头的地址');
      if (u.length > 300) v.bad('baseUrl', 'baseUrl 太长了');
      cols.base_url = u;
    }
    if (!patch || b.model !== undefined) cols.model = v.str(b.model, 'model', { max: 120 });
    if (b.isDefault !== undefined) cols.is_default = v.bool(b.isDefault, 'isDefault') ? 1 : 0;
    else if (!patch) cols.is_default = 0;
    if (b.enabled !== undefined) cols.enabled = v.bool(b.enabled, 'enabled') ? 1 : 0;
    else if (!patch) cols.enabled = 1;
    if (b.extra !== undefined) {
      if (!v.isObject(b.extra)) v.bad('extra', 'extra 必须是对象');
      readExtra(b.extra);
      const s = JSON.stringify(b.extra);
      if (s.length > 4000) v.bad('extra', 'extra 太大了');
      cols.extra = s;
    } else if (!patch) cols.extra = '{}';

    // 密钥：缺省或空串 = 不改（新建时 = 没有密钥）
    const raw = typeof b.apiKey === 'string' ? b.apiKey.trim() : '';
    const changing = typeof b.apiKey === 'string' && raw !== '';
    if (changing) {
      if (raw.length > 400) v.bad('apiKey', 'apiKey 太长了');
      cols.api_key_enc = encrypt(secret, raw);
    }
    // 最终会不会有密钥？没有的话，只有本机地址（Ollama 之类）才放行。
    const willHaveKey = changing || (patch && !!existing.api_key_enc);
    const finalBase = cols.base_url || (patch ? existing.base_url : '');
    if (!willHaveKey && !providers.isLocalHost(finalBase)) {
      v.bad('apiKey', '这个地址需要 API 密钥；只有本机服务（如 Ollama）可以留空');
    }
    return cols;
  }

  /**
   * extra 里认得的几个键先校验：requestExtras 只收白名单里的参数（spec §4），importMaxTokens 是导入单次输出上限的
   * 渠道覆盖（256–64000）。别的键（P5 的 vision 等）原样存。
   */
  function readExtra(extra) {
    const rx = extra.requestExtras;
    if (rx !== undefined && rx !== null) {
      if (!v.isObject(rx)) v.bad('extra', 'requestExtras 必须是对象');
      const unknown = Object.keys(rx).filter((k) => !providers.REQUEST_EXTRA_KEYS.includes(k));
      if (unknown.length) {
        v.bad('extra', `不支持的附加参数：${unknown.join('、')}（可用：${providers.REQUEST_EXTRA_KEYS.join('、')}）`);
      }
    }
    if (extra.importMaxTokens !== undefined && extra.importMaxTokens !== null) {
      v.int(extra.importMaxTokens, 'extra', { min: 256, max: 64000 });
    }
  }

  /** 同时只能有一个默认渠道。 */
  function clearOtherDefaults(id, now) {
    db.run('UPDATE ai_providers SET is_default = 0, updated_at = ? WHERE id != ? AND is_default = 1', now, id);
  }

  // ------------------------------------------------------------ providers

  function listPresets(req, res) {
    sendJson(res, 200, { items: providers.PRESETS });
  }

  function listProviders(req, res) {
    const rows = db.all(`SELECT ${COLUMNS} FROM ai_providers ORDER BY is_default DESC, created_at, id`);
    sendJson(res, 200, { items: rows.map(toJson) });
  }

  function createProvider(req, res, reqCtx) {
    const b = v.body(reqCtx.body);
    const cols = readWrite(b, null);
    const now = db.now();
    const id = crypto.randomUUID();
    db.tx(() => {
      db.run(
        'INSERT INTO ai_providers(id, name, kind, base_url, api_key_enc, model, is_default, enabled, extra, created_at, updated_at)' +
          ' VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
        id, cols.name, cols.kind, cols.base_url, cols.api_key_enc ?? null, cols.model,
        cols.is_default, cols.enabled, cols.extra, now, now,
      );
      if (cols.is_default) clearOtherDefaults(id, now);
      logActivity(db, { memberId: reqCtx.member.id, action: 'create', entity: 'ai_provider', entityId: id, at: now });
    });
    log.info('ai', `渠道新建 ${cols.kind}/${cols.model} by ${reqCtx.member.username}`);
    sendJson(res, 201, { provider: toJson(byId(id)) });
  }

  function patchProvider(req, res, reqCtx) {
    const row = byId(reqCtx.params.id);
    if (!row) throw new HttpError(404, 'not_found', 'AI 渠道不存在');
    const cols = readWrite(v.body(reqCtx.body), row);
    // 换了协议、地址或模型：上次测出来的「能不能看图」不算数了，回到「没测过」（表单带着旧的 extra 发回来也一样拿掉）。
    if (VISION_KEYS.some((k) => cols[k] !== undefined && cols[k] !== row[k])) {
      const extra = extraOf({ ...row, extra: cols.extra ?? row.extra });
      if ('vision' in extra) {
        delete extra.vision;
        cols.extra = JSON.stringify(extra);
      }
    }
    const now = db.now();
    db.tx(() => {
      const keys = Object.keys(cols);
      if (keys.length) {
        db.run(
          `UPDATE ai_providers SET ${keys.map((k) => `${k} = ?`).join(', ')}, updated_at = ? WHERE id = ?`,
          ...keys.map((k) => cols[k]), now, row.id,
        );
      } else {
        db.run('UPDATE ai_providers SET updated_at = ? WHERE id = ?', now, row.id);
      }
      if (cols.is_default) clearOtherDefaults(row.id, now);
      logActivity(db, { memberId: reqCtx.member.id, action: 'update', entity: 'ai_provider', entityId: row.id, at: now });
    });
    sendJson(res, 200, { provider: toJson(byId(row.id)) });
  }

  function deleteProvider(req, res, reqCtx) {
    const row = byId(reqCtx.params.id);
    if (!row) throw new HttpError(404, 'not_found', 'AI 渠道不存在');
    db.tx(() => {
      db.run('DELETE FROM ai_providers WHERE id = ?', row.id);
      logActivity(db, { memberId: reqCtx.member.id, action: 'delete', entity: 'ai_provider', entityId: row.id });
    });
    sendJson(res, 200, { ok: true, id: row.id });
  }

  /** 一次最短的真实往返。上游坏了也回 200 —— 这是「测试结果」，不是接口错误。 */
  async function testProvider(req, res, reqCtx) {
    takeToken(reqCtx);
    const row = byId(reqCtx.params.id);
    if (!row) throw new HttpError(404, 'not_found', 'AI 渠道不存在');
    if (reqCtx.query.vision === '1') return testVision(res, reqCtx, row);
    const use = toUse(row);
    const started = Date.now();
    try {
      const out = await providers.complete(use, {
        system: '你在做一次连通性自检。',
        messages: [{ role: 'user', content: '回复“OK”' }],
        maxTokens: TEST_MAX_TOKENS,
      });
      sendJson(res, 200, {
        ok: true,
        model: row.model,
        latencyMs: Date.now() - started,
        sample: (out.text || '').trim().slice(0, 200),
        usage: out.usage,
      });
    } catch (e) {
      const message = friendly(e, use.apiKey);
      log.warn('ai', `渠道自检失败 ${row.kind}/${row.model}: ${message}`);
      sendJson(res, 200, { ok: false, model: row.model, latencyMs: Date.now() - started, message });
    }
  }

  /**
   * 看图探测（spec §4）。明确答出「红色 / red」→ vision:true（判定规则在 lib/vision_probe.js：否定、反问、猜测、
   * delivered 这类子串、同时说别的颜色都不算）；答了别的或上游 400 说不收图片 → vision:false；
   * 连不上、401、5xx、超时、没回答 → 判断不了，extra 不动，vision:null。
   * 写回时重新读这一行（探测要等上游，期间可能有人改过或删了渠道）：删了回 404；协议、地址、模型换了，这次结论不算数
   * （vision:null，请人重测）；没换就把 vision 合进**现在的** extra（期间别的键的改动不会被回滚）。
   */
  async function testVision(res, reqCtx, row) {
    const use = toUse(row);
    const started = Date.now();
    let vision = null;
    let sample = '';
    let message = '';
    let usage = null;
    try {
      const out = await providers.complete(use, {
        system: '你在做一次看图自检。',
        messages: [{ role: 'user', content: [
          { type: 'image', mediaType: 'image/png', data: VISION_PNG },
          { type: 'text', text: '这张图是什么颜色？只回答一个颜色词。' },
        ] }],
        maxTokens: VISION_TEST_MAX_TOKENS,
      });
      sample = (out.text || '').trim().slice(0, 200);
      usage = out.usage;
      if (!sample) message = '模型没有回答，判断不了能不能看图；换个模型或关掉思考再测';
      else if (judgeVisionAnswer(sample)) vision = true;
      else {
        vision = false;
        message = `它说「${sample.slice(0, 40)}」，看起来没看到图`;
      }
    } catch (e) {
      if (e instanceof providers.UpstreamError && e.status === 400 && NO_VISION_HINT.test(e.snippet)) {
        vision = false;
        message = '这个模型不收图片（上游回了 400）';
      } else {
        message = friendly(e, use.apiKey);
      }
    }
    if (vision !== null) {
      const outcome = db.tx(() => {
        const now = byId(row.id);
        if (!now) return 'gone';
        if (VISION_KEYS.some((k) => now[k] !== row[k])) return 'changed';
        db.run('UPDATE ai_providers SET extra = ?, updated_at = ? WHERE id = ?', JSON.stringify({ ...extraOf(now), vision }), db.now(), row.id);
        logActivity(db, { memberId: reqCtx.member.id, action: 'update', entity: 'ai_provider', entityId: row.id });
        return 'written';
      });
      if (outcome === 'gone') throw new HttpError(404, 'not_found', 'AI 渠道在测看图的时候被删了');
      if (outcome === 'changed') {
        vision = null;
        message = '测的时候渠道被改过（换了协议、地址或模型），这次的结果不算数，再测一次';
      }
    }
    const latest = byId(row.id);
    if (!latest) throw new HttpError(404, 'not_found', 'AI 渠道在测看图的时候被删了');
    log.info('ai', `看图探测 ${row.kind}/${row.model}：${vision === null ? '判断不了' : vision ? '能看图' : '看不了图'}`);
    sendJson(res, 200, {
      ok: vision !== null,
      vision,
      model: row.model,
      latencyMs: Date.now() - started,
      sample,
      message,
      usage,
      provider: toJson(latest),
    });
  }

  // ------------------------------------------------------------------ 流

  /**
   * 占一条上游流的名额跑 [fn]，名额在 finally 里还（正常收尾、上游报错、客户端半路跑了都从这里过）。
   * 名额要在 openSse 之前抢：抢不到才能回一个干净的 503 JSON。
   */
  async function withStreamSlot(fn) {
    if (liveStreams >= maxStreams) {
      throw new HttpError(503, 'ai_busy', `同时进行的 AI 会话已达上限（${maxStreams} 条），等前一条说完再试`);
    }
    liveStreams++;
    try {
      return await fn();
    } finally {
      liveStreams--;
    }
  }

  /**
   * 把一次上游流式对话转成自家 SSE。HttpError 必须在进这里之前抛完 —— 头一旦发出去
   * 就只能用 error 事件报错了。
   * @param {(out:{text:string, usage:object, stopReason:string})=>object|undefined} [onComplete] 落库钩子，返回值并进 done
   */
  async function runStream(req, res, row, payload, onComplete) {
    await withStreamSlot(async () => {
      const use = toUse(row);
      const sse = openSse(res);
      const ctl = new AbortController();
      const onClose = () => ctl.abort();
      res.on('close', onClose);
      const started = Date.now();
      try {
        const out = await providers.streamChat(use, { ...payload, signal: ctl.signal }, (text) => sse.send('delta', { text }));
        const extra = (onComplete && onComplete(out)) || {};
        sse.send('done', { usage: out.usage, providerId: row.id, model: row.model, ...extra });
        log.info(
          'ai',
          `流式完成 ${row.kind}/${row.model} 输出 ${out.text.length} 字 token ${out.usage.input}/${out.usage.output} ${Date.now() - started}ms`,
        );
      } catch (e) {
        if (ctl.signal.aborted) {
          log.debug('ai', `客户端断开，已中止上游 ${row.kind}/${row.model}（${Date.now() - started}ms）`);
        } else {
          const message = friendly(e, use.apiKey);
          log.warn('ai', `流式失败 ${row.kind}/${row.model}: ${message}`);
          sse.send('error', { message });
        }
      } finally {
        res.off('close', onClose);
        sse.close();
      }
    });
  }

  /** `[{role:'user'|'assistant', content}]`，最多 40 条、每条 8000 字。 */
  function readMessages(raw) {
    const list = v.list(raw, 'messages', { max: MAX_MESSAGES, required: true });
    if (list.length === 0) v.bad('messages', 'messages 不能为空');
    const msgs = list.map((m) => {
      if (!v.isObject(m)) v.bad('messages', 'messages 的每一项都必须是对象');
      return {
        role: v.enumOf(m.role, 'role', ['user', 'assistant']),
        content: v.str(m.content, 'content', { max: MAX_MESSAGE_CHARS, trim: false }),
      };
    });
    // Anthropic 要求第一条是 user、且相邻两条不能同角色。cc-trans 这类严格反代
    // 不会替你合并，所以这里自己来：先丢掉开头的 assistant（客户端从缓存恢复会话
    // 时很容易把上一轮的回复排在最前面），再把相邻同角色的合并成一条。
    const firstUser = msgs.findIndex((m) => m.role === 'user');
    // 注意不能写成 slice(findIndex(...))：没有 user 时 findIndex 回 -1，
    // slice(-1) 会留下最后一条 assistant，正好是最不该发出去的那种请求。
    if (firstUser < 0) v.bad('messages', 'messages 里至少要有一条 user 消息');
    const kept = msgs.slice(firstUser);
    const merged = [];
    for (const m of kept) {
      const last = merged[merged.length - 1];
      if (last && last.role === m.role) last.content += `\n\n${m.content}`;
      else merged.push({ ...m });
    }
    return merged;
  }

  function systemFor(month) {
    return `${prompts.SYSTEM_PROMPT}\n\n${prompts.buildFinanceContext(db, month)}`;
  }

  async function chat(req, res, reqCtx) {
    takeToken(reqCtx);
    const b = v.body(reqCtx.body);
    const messages = readMessages(b.messages);
    const context = v.isObject(b.context) ? b.context : {};
    const month = context.month ? v.month(context.month, 'month') : stats.currentMonth();
    const row = pickProvider(b.providerId); // 这几行的 400/404 都发生在 SSE 开始之前
    const system = systemFor(month);
    log.info('ai', `对话 ${row.kind}/${row.model} ${messages.length} 条消息 ${messages.reduce((n, m) => n + m.content.length, 0)} 字`);
    log.debug('ai', `system=${system}`);
    await runStream(req, res, row, { system, messages, maxTokens: CHAT_MAX_TOKENS });
  }

  async function report(req, res, reqCtx) {
    takeToken(reqCtx);
    const b = v.isObject(reqCtx.body) ? reqCtx.body : {};
    const month = reqCtx.query.month ? v.month(reqCtx.query.month, 'month') : stats.currentMonth();
    const row = pickProvider(reqCtx.query.providerId || b.providerId);
    const system = systemFor(month);
    log.info('ai', `月报 ${month} ${row.kind}/${row.model}`);

    await runStream(
      req, res, row,
      { system, messages: [{ role: 'user', content: prompts.REPORT_PROMPT(month) }], maxTokens: REPORT_MAX_TOKENS },
      (out) => {
        const content = (out.text || '').trim();
        if (!content) return {};
        const id = crypto.randomUUID();
        db.run('INSERT INTO ai_reports(id, month, provider_id, content, created_at) VALUES(?, ?, ?, ?, ?)', id, month, row.id, content, db.now());
        return { reportId: id, month };
      },
    );
  }

  function listReports(req, res, reqCtx) {
    const month = reqCtx.query.month ? v.month(reqCtx.query.month, 'month') : null;
    const limit = reqCtx.query.limit ? v.int(reqCtx.query.limit, 'limit', { min: 1, max: 50 }) : REPORTS_LIMIT;
    const rows = month
      ? db.all('SELECT * FROM ai_reports WHERE month = ? ORDER BY created_at DESC, id DESC LIMIT ?', month, limit)
      : db.all('SELECT * FROM ai_reports ORDER BY created_at DESC, id DESC LIMIT ?', limit);
    sendJson(res, 200, { items: rows.map((r) => rowToJson(r)) });
  }

  // -------------------------------------------------------------- classify

  /** 代码块、前后废话都容忍；取第一个 `{` 到最后一个 `}`。 */
  function parseLooseJson(text) {
    if (typeof text !== 'string') return null;
    let s = text.trim();
    const fence = s.match(/```(?:json)?\s*([\s\S]*?)```/i);
    if (fence) s = fence[1].trim();
    const i = s.indexOf('{');
    const j = s.lastIndexOf('}');
    if (i < 0 || j <= i) return null;
    try {
      const o = JSON.parse(s.slice(i, j + 1));
      return v.isObject(o) ? o : null;
    } catch {
      return null;
    }
  }

  function readCandidates(raw, field) {
    const list = v.list(raw, field, { max: MAX_CANDIDATES });
    return list.map((c) => {
      if (!v.isObject(c)) v.bad(field, `${field} 的每一项都必须是 {id, name}`);
      return { id: v.str(c.id, `${field}Id`, { max: 64 }), name: v.str(c.name, `${field}Name`, { max: 100 }) };
    });
  }

  async function classify(req, res, reqCtx) {
    takeToken(reqCtx);
    const b = v.body(reqCtx.body);
    const input = {
      text: v.str(b.text, 'text', { max: 2000 }),
      merchant: v.optStr(b.merchant, 'merchant', { max: 200 }),
      amountCents: v.optInt(b.amountCents, 'amountCents', { min: 0, max: 1e14 }),
    };
    if (!v.isObject(b.candidates)) v.bad('candidates', 'candidates 必须是 {categories, funds}');
    const candidates = {
      categories: readCandidates(b.candidates.categories, 'categories'),
      funds: readCandidates(b.candidates.funds, 'funds'),
    };
    const row = pickProvider(b.providerId);
    const use = toUse(row);
    // 原始通知文本可能带姓名、卡号 —— info 只记长度（spec §8）。
    log.info('ai', `分类 ${row.kind}/${row.model} 文本 ${input.text.length} 字 候选 ${candidates.categories.length}/${candidates.funds.length}`);
    log.debug('ai', `分类文本=${input.text} 商户=${input.merchant || ''}`);

    let out;
    try {
      out = await providers.complete(use, {
        system: prompts.CLASSIFY_SYSTEM,
        messages: [{ role: 'user', content: prompts.CLASSIFY_PROMPT(input, candidates) }],
        maxTokens: CLASSIFY_MAX_TOKENS,
        json: true,
      });
    } catch (e) {
      throw new HttpError(502, 'ai_upstream', friendly(e, use.apiKey));
    }

    const parsed = parseLooseJson(out.text);
    if (!parsed) {
      log.warn('ai', `分类输出不是 JSON（${(out.text || '').length} 字）`);
      throw new HttpError(502, 'ai_bad_output', '模型没有按要求返回 JSON');
    }
    const pick = (value, list) => (list.some((c) => c.id === value) ? value : null);
    const confidence = Number(parsed.confidence);
    sendJson(res, 200, {
      categoryId: pick(parsed.categoryId, candidates.categories),
      fundId: pick(parsed.fundId, candidates.funds),
      confidence: Number.isFinite(confidence) ? Math.min(1, Math.max(0, confidence)) : 0,
      reason: typeof parsed.reason === 'string' ? parsed.reason.slice(0, 200) : null,
      providerId: row.id,
      model: row.model,
      usage: out.usage,
    });
  }

  log.debug('ai', `限流 ${aiPerMin}/min/人，并发流上限 ${maxStreams}`);

  ctx.ai = { pickProvider, takeToken, toUse, friendly, withStreamSlot };

  return {
    name: 'ai',
    routes: [
      { method: 'GET', pattern: '/ai/presets', handler: listPresets, maxBody: 0 },
      { method: 'GET', pattern: '/ai/providers', handler: listProviders, maxBody: 0 },
      { method: 'POST', pattern: '/ai/providers', handler: createProvider, auth: 'admin' },
      { method: 'PATCH', pattern: '/ai/providers/:id', handler: patchProvider, auth: 'admin' },
      { method: 'DELETE', pattern: '/ai/providers/:id', handler: deleteProvider, auth: 'admin' },
      { method: 'POST', pattern: '/ai/providers/:id/test', handler: testProvider, auth: 'admin' },
      { method: 'POST', pattern: '/ai/chat', handler: chat, maxBody: CHAT_MAX_BODY },
      { method: 'POST', pattern: '/ai/report', handler: report },
      { method: 'GET', pattern: '/ai/reports', handler: listReports, maxBody: 0 },
      { method: 'POST', pattern: '/ai/classify', handler: classify, maxBody: 128 * 1024 },
    ],
  };
};
