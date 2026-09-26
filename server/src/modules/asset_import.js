'use strict';

// AI 智能导入（spec §4、§6）：虚拟资产（平台 → 会员/卡 → 权益）和实物共用一条管线，先抽出可编辑的预览，确认后才落库。
//
//   POST /asset-import/extract   SSE：stage → record*（已识别 N 条）→ done{importId, draft} | error{code, message}
//   POST /asset-import/apply     单个事务落库（lib/perk_import_apply.js），只增改、不删
//   POST /asset-import/:id/undo  7 天内整批撤销（lib/perk_import_undo.js）；本人或管理员；撤销过的再来原样回上次的结果
//   GET  /asset-import/recent    7 天内导入了、还没撤销的（App「最近的 AI 导入」列出来逐个撤）：本人的；管理员看全家的
//   GET  /asset-import/candidates?months=13   从流水里挑像订阅的扣费分组（lib/subscription_detect.js），纯规则、不花 token
//   POST /asset-import/fetch     抓一个网页的正文（lib/page_fetch.js 负责防 SSRF），App 放进文本框给人改，再按 kind=url 发来识别
//
// 来源：
//   kind=text          粘贴文字；
//   kind=image         截图（App 切好片、缩好、编成 PNG，这里 lib/perk_import_image.js 只守门，渠道要看得了图 ——
//                      pickProvider(…, {needVision:true})）；
//   kind=url           网址：App 先 fetch 拿到正文、给人改过，再连同 sourceUrl 发来。服务端不再抓，当粘贴文字一样识别，
//                      只是 ai_imports 记下 source_kind='url' 和 source_url；
//   kind=transactions  从流水识别：groups 是勾选的候选分组 key（服务端按同样的 months 重算一遍候选对上）。useAi=false
//                      「直接生成」不调模型（没有渠道也能用、不占限流）；useAi=true「AI 整理名称」只把规范化商户、金额、周期、
//                      次数发给模型起名（lib/subscription_import.js；商户名是从备注来的组只发金额和周期拼的占位名，备注不发），
//                      费用、日期、扣费特征一律用流水里观测到的。
//
// 截断（stopReason = max_tokens 或没有 done 哨兵）且已经收到 ≥ CONTINUE_MIN 条时，带着「已收到」名单续写一次
// （同一个导入、同一个流名额，不另算限流；总时长仍是 AI_IMPORT_TOTAL_MS）。草稿（和 ai_imports.summary）用三个标记说清楚
// 截断的情形，App 照着在预览顶部说哪种情况、提示分段导入（截断那句不再放进 notices）：
//   truncated        最后仍没写完；continued  续写过（试过）一次；continueFailed  续写那次出错了（上游报错、超时）。
// 续写期间客户端断开：第一次的用量已经知道了，照样记一行 ai_imports（status failed，error client_aborted）。
//
// 花钱的闸门（除了 ai.js 的每人每分钟和并发流名额）：
//   · 每人每小时 AI_IMPORT_PER_HOUR 次（默认 20），超了 429 rate_limited；
//   · 每人同时只能有 1 个导入在跑，第二个 409 import_in_progress（名额在 finally 里还，客户端半路跑了也照还）；
//   · 60 秒没收到新数据算超时（AI_IMPORT_IDLE_MS），整次导入最长 300 秒（AI_IMPORT_TOTAL_MS）—— 两个变量只给测试调小。
//
// 日志：info 只记长度和用量；原文只进 debug。发给模型前先脱敏（手机号打码、卡号只留尾号，lib/redact.js）。
//
// 抓网页另有一个桶：每人每分钟 URL_FETCH_PER_MIN 次（默认 10），超了 429 rate_limited；URL_FETCH_TIMEOUT_MS 只给测试调小（默认 10 秒）。
// URL_FETCH_ALLOW_FAKEIP=1 放开 fake-ip 段 198.18.0.0/15（服务端网络用了 Clash 这类 fake-ip 代理时）。放开后 DNS 回的是代理的
// 假地址，真实目标由代理自己去连、服务端核实不了 —— 解析到内网的域名也拦不住。所以放开时：抓网页只给管理员用（成员 403
// url_fetch_admin_only），page_fetch 另外不收 IP 直写、单段主机名和内网后缀；启动时 warn 一句。环境变量只在启动时读。

const crypto = require('node:crypto');

const { HttpError, sendJson } = require('../lib/router');
const { RateLimiter } = require('../lib/ratelimit');
const { openSse } = require('../lib/sse');
const idem = require('../lib/idempotency');
const v = require('../lib/validate');
const { redactPii } = require('../lib/redact');
const { pickParagraphs } = require('../lib/perk_import_text');
const { parseImportOutput, createRecordCounter } = require('../lib/perk_import_parse');
const { normalizeImport } = require('../lib/perk_import_normalize');
const { matchImport } = require('../lib/perk_import_match');
const { buildImportPrompt, continueNote, IMPORT_MAX_TOKENS, MAX_EXISTING } = require('../lib/perk_import_prompt');
const { applyImport } = require('../lib/perk_import_apply');
const { undoImport } = require('../lib/perk_import_undo');
const { readImages } = require('../lib/perk_import_image');
const perks = require('../lib/perks_schema');
const detect = require('../lib/subscription_detect');
const subs = require('../lib/subscription_import');
const pageFetch = require('../lib/page_fetch');

const providers = require('./ai_providers');

const KINDS = ['text', 'image', 'url', 'transactions'];
const WANTS = ['auto', 'virtual', 'items'];
const MAX_TEXT = 20000;
const EXTRACT_MAX_BODY = 8 * 1024 * 1024;
const APPLY_MAX_BODY = 1024 * 1024;
const FETCH_MAX_BODY = 8 * 1024;
const KEEP_DAYS = 90;
const UNDO_DAYS = 7;
/** 截断后至少收到这么多条才续写（太少多半是模型根本没按格式写，续写也救不回来）。 */
const CONTINUE_MIN = 5;
/** 续写前剩下的总时长不到这么多就不续了（续到一半被总超时掐断，白花 token）。 */
const CONTINUE_MIN_LEFT_MS = 15000;

/** 和 ai.js 的 envInt 同义：缺失或非法一律回默认值。 */
function envInt(name, dflt, min = 1) {
  const n = Number(process.env[name]);
  return Number.isFinite(n) && Number.isInteger(n) && n >= min ? n : dflt;
}

module.exports = (ctx) => {
  const { db, log } = ctx;

  const perHour = envInt('AI_IMPORT_PER_HOUR', 20);
  const idleMs = envInt('AI_IMPORT_IDLE_MS', 60000);
  const totalMs = envInt('AI_IMPORT_TOTAL_MS', 300000);
  const hourly = new RateLimiter(perHour / 60, perHour);
  /** 正在导入的成员 id：每人同时 1 个。 */
  const running = new Set();
  const fetchPerMin = envInt('URL_FETCH_PER_MIN', 10);
  const fetchTimeoutMs = envInt('URL_FETCH_TIMEOUT_MS', pageFetch.TIMEOUT_MS);
  const allowFakeIp = process.env.URL_FETCH_ALLOW_FAKEIP === '1';
  const fetches = new RateLimiter(fetchPerMin, fetchPerMin);

  /** 给模型看的已有名字：平台和卡各最多 80 个（没归档的在前）。 */
  function existingNames() {
    const platforms = db
      .all('SELECT name FROM platforms WHERE deleted_at IS NULL ORDER BY archived, sort_order, created_at LIMIT ?', MAX_EXISTING)
      .map((r) => r.name);
    const memberships = db
      .all(
        'SELECT m.name AS name, p.name AS platform FROM memberships m JOIN platforms p ON p.id = m.platform_id' +
          ' WHERE m.deleted_at IS NULL ORDER BY m.archived, m.sort_order, m.created_at LIMIT ?',
        MAX_EXISTING,
      )
      .map((r) => ({ name: r.name, platform: r.platform }));
    return { platforms, memberships };
  }

  function counts(draft) {
    return { platforms: draft.platforms.length, memberships: draft.memberships.length, benefits: draft.benefits.length, items: draft.items.length };
  }

  /** 记一行用量（extract 结束时；用户最后没导入也有记录），顺手清掉 90 天前的。「直接生成」没有渠道：row 是 null。 */
  function recordImport({ id, reqCtx, status, row, usage, summary, sourceKind, sourceUrl = null }) {
    const now = db.now();
    db.tx(() => {
      db.run(
        'INSERT INTO ai_imports(id, member_id, created_at, status, source_kind, source_url, provider_id, model, usage_in, usage_out, summary)' +
          ' VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
        id, reqCtx.member.id, now, status, sourceKind, sourceUrl, row ? row.id : null, row ? row.model : null,
        (usage && usage.input) || 0, (usage && usage.output) || 0, JSON.stringify(summary),
      );
      db.run('DELETE FROM ai_imports WHERE created_at < ?', new Date(Date.now() - KEEP_DAYS * 86400000).toISOString());
    });
  }

  async function extract(req, res, reqCtx) {
    const b = v.body(reqCtx.body);
    const kind = b.kind === undefined || b.kind === null ? 'text' : v.enumOf(b.kind, 'kind', KINDS);
    if (kind === 'transactions') return fromTransactions(res, reqCtx, b);
    const want = b.want === undefined || b.want === null ? 'auto' : v.enumOf(b.want, 'want', WANTS);
    let input;
    if (kind === 'image') {
      input = { kind, images: readImages(b.images) };
    } else {
      const raw = v.str(b.text, 'text', { max: MAX_TEXT, trim: false });
      if (!raw.trim()) v.bad('text', kind === 'url' ? '先抓取网页，或者把正文粘进来' : '先粘点东西进来');
      // 网址：正文是 App 抓来、给人改过的；sourceUrl 只记下来（写进 ai_imports.source_url），不再去抓。
      const sourceUrl = kind === 'url' ? pageFetch.parseTarget(b.sourceUrl, 'sourceUrl').href : null;
      input = { kind, raw, sourceUrl };
    }
    let target = null;
    if (!v.isMissing(b.targetMembershipId) && b.targetMembershipId !== '') {
      const id = v.str(b.targetMembershipId, 'targetMembershipId', { max: 64 });
      target = db.get(
        'SELECT m.id AS id, m.name AS name, p.name AS platform FROM memberships m JOIN platforms p ON p.id = m.platform_id' +
          ' WHERE m.id = ? AND m.deleted_at IS NULL',
        id,
      );
      if (!target) v.bad('targetMembershipId', '要补充权益的那张卡不存在');
    }

    const memberId = reqCtx.member.id;
    if (running.has(memberId)) {
      throw new HttpError(409, 'import_in_progress', '你还有一次识别没结束，等它结束或取消后再试');
    }
    running.add(memberId);
    try {
      ctx.ai.takeToken(reqCtx);
      if (!hourly.allow(memberId)) {
        log.warn('import', `成员 ${reqCtx.member.username} 触发导入限流（${perHour}/h）`);
        throw new HttpError(429, 'rate_limited', `识别太频繁了（每小时最多 ${perHour} 次），过一会儿再试`);
      }
      const row = ctx.ai.pickProvider(b.providerId, { needVision: kind === 'image' });
      await ctx.ai.withStreamSlot(() => run(res, reqCtx, row, { input, want, target }));
    } finally {
      running.delete(memberId);
    }
  }

  /**
   * 这次要发给模型的东西：文字 → 挑段落、脱敏后的原文（依据核对也用它）；截图 → 图片块在前、说明文字在后。
   * content(note) 返回 user 消息的 content；note 是续写时附在文字部分末尾的一段（Task 4），首次发送给 null。
   */
  function prepare(input, prompt) {
    if (input.kind === 'image') {
      const { images } = input;
      const bytes = images.reduce((n, i) => n + i.bytes, 0);
      const blocks = images.map((i) => ({ type: 'image', mediaType: i.mediaType, data: i.data }));
      const text = prompt.userForImages(images.length);
      return {
        source: '',
        notices: [],
        logLine: `截图 ${images.length} 块 共 ${Math.round(bytes / 1024)}KB`,
        summary: { sourceKind: 'image', images: images.length, bytes },
        draftSource: { kind: 'image', count: images.length },
        imageCount: images.length,
        content: (note) => [...blocks, { type: 'text', text: note ? `${text}\n\n${note}` : text }],
      };
    }
    const { raw } = input;
    const picked = pickParagraphs(raw);
    const { text: source, phones, cards } = redactPii(picked.text);
    const notices = [];
    if (picked.picked) notices.push(`材料有 ${raw.length} 字，只挑了最相关的 ${picked.kept} 段（约 ${source.length} 字）`);
    log.debug('import', `原文=${source}${input.sourceUrl ? ` 来源=${input.sourceUrl}` : ''}`);
    return {
      source,
      notices,
      logLine: `${input.kind === 'url' ? '网页正文' : '原文'} ${raw.length} 字 发送 ${source.length} 字 打码 ${phones}/${cards}`,
      summary: { sourceKind: input.kind, textLength: raw.length, sentLength: source.length },
      draftSource: input.kind === 'url' ? { kind: 'url', text: source, url: input.sourceUrl } : { kind: 'text', text: source },
      imageCount: 0,
      content: (note) => (note ? `${prompt.user(source)}\n\n${note}` : prompt.user(source)),
    };
  }

  async function run(res, reqCtx, row, { input, want, target }) {
    const use = ctx.ai.toUse(row);
    const prompt = buildImportPrompt({ want, existing: existingNames(), target: target && { name: target.name, platform: target.platform } });
    const prep = prepare(input, prompt);
    const maxTokens = Number.isInteger(use.extra.importMaxTokens) ? use.extra.importMaxTokens : IMPORT_MAX_TOKENS;
    const { notices } = prep;
    // info 只记长度和用量；图片的 base64 哪一级都不记。
    log.info('import', `识别 ${row.kind}/${row.model} ${prep.logLine} want=${want}`);

    const sse = openSse(res);
    const ctl = new AbortController();
    const onClose = () => ctl.abort();
    res.on('close', onClose);
    const started = Date.now();
    /** 第一次问完就知道的用量和摘要（续写到一半客户端断开时也要记进 ai_imports）。 */
    let usage = null;
    let summaryBase = null;
    try {
      sse.send('stage', { stage: 'asking', message: notices[0] || (input.kind === 'image' ? '正在请模型看图…' : '正在请模型识别…') });
      let seen = 0;
      /** 流一次：base 是之前已经收到的条数（续写时进度接着往上数）。 */
      const ask = async (content, base, timeoutMs) => {
        const counter = createRecordCounter();
        return providers.streamChat(
          use,
          { system: prompt.system, messages: [{ role: 'user', content }], maxTokens, signal: ctl.signal, timeoutMs, idleMs },
          (delta) => {
            const n = base + counter.push(delta);
            if (n > seen) {
              seen = n;
              sse.send('record', { n });
            }
          },
        );
      };
      const out = await ask(prep.content(null), 0, totalMs);
      usage = { input: out.usage.input || 0, output: out.usage.output || 0 };
      summaryBase = { want, ...prep.summary, stopReason: out.stopReason };
      let parsed = parseImportOutput(out.text);
      if (!parsed.ok) {
        recordImport({
          id: crypto.randomUUID(), reqCtx, status: 'failed', row, usage, summary: { ...summaryBase, error: 'ai_bad_output' },
          sourceKind: input.kind, sourceUrl: input.sourceUrl,
        });
        log.warn('import', `模型输出解析不了（${out.text.length} 字，stop=${out.stopReason}）`);
        const refused = out.stopReason === 'refusal';
        sse.send('error', {
          code: refused ? 'ai_refusal' : 'ai_bad_output',
          message: refused ? '模型拒绝处理这段材料，换个渠道或删掉敏感内容再试' : '模型没有按要求返回结果，换个渠道或把材料删短一点再试',
        });
        return;
      }
      let truncated = out.stopReason === 'max_tokens' || !parsed.done;
      let continued = false;
      let continueFailed = false;
      const left = totalMs - (Date.now() - started);
      if (truncated && parsed.records.length >= CONTINUE_MIN && left >= CONTINUE_MIN_LEFT_MS) {
        continued = true;
        sse.send('stage', { stage: 'continuing', message: `材料较长，模型写了 ${parsed.records.length} 条没写完，正在让它接着写…` });
        let more = null;
        try {
          more = await ask(prep.content(continueNote(parsed.records)), parsed.records.length, left);
        } catch (e) {
          if (ctl.signal.aborted) throw e;
          // 续写那次失败（上游出错、超时）：第一次收到的留着、照截断处理 —— 那部分的 token 已经花了，不能跟着一起丢掉。
          continueFailed = true;
          log.warn('import', `续写失败，保留第一次的 ${parsed.records.length} 条：${ctx.ai.friendly(e, use.apiKey)}`);
        }
        if (more) {
          usage.input += more.usage.input || 0;
          usage.output += more.usage.output || 0;
          const tail = parseImportOutput(more.text);
          if (tail.ok) {
            parsed = { ok: true, records: [...parsed.records, ...tail.records], done: tail.done, salvaged: parsed.salvaged || tail.salvaged };
            truncated = more.stopReason === 'max_tokens' || !tail.done;
          }
          log.info('import', `续写一次：又收到 ${tail.ok ? tail.records.length : 0} 条（stop=${more.stopReason}，仍截断 ${truncated}）`);
        }
      }
      sse.send('stage', { stage: 'matching', message: '正在和账本里已有的对一对…' });
      // 网址抓来的正文和粘贴的文字一样核对依据。
      const draft = normalizeImport(parsed.records, {
        want, source: prep.source, sourceKind: input.kind === 'image' ? 'image' : 'text', imageCount: prep.imageCount, today: v.localDay(), target,
      });
      matchImport(db, draft);
      if (!parsed.records.length) notices.push('材料里没找到会员、权益或买的东西');
      const importId = crypto.randomUUID();
      recordImport({
        id: importId, reqCtx, status: 'extracted', row, usage, sourceKind: input.kind, sourceUrl: input.sourceUrl,
        summary: { ...summaryBase, counts: counts(draft), truncated, continued, continueFailed, salvaged: parsed.salvaged, dropped: draft.dropped },
      });
      sse.send('done', {
        importId,
        draft: {
          ...draft, importId, want, truncated, continued, continueFailed, salvaged: parsed.salvaged, notices,
          targetMembershipId: target ? target.id : null,
          source: prep.draftSource,
          providerId: row.id, model: row.model, usage,
        },
      });
      log.info(
        'import',
        `识别完成 ${row.kind}/${row.model} ${parsed.records.length} 条（截断 ${truncated}，续写 ${continued}，抢救 ${parsed.salvaged}） token ${usage.input}/${usage.output} ${Date.now() - started}ms`,
      );
    } catch (e) {
      if (ctl.signal.aborted) {
        log.debug('import', `客户端断开，已中止上游 ${row.kind}/${row.model}（${Date.now() - started}ms）`);
        // 断在续写那次：第一次已经花掉的 token 是知道的，照样记账（spec「每次用量记入 ai_imports」）。
        if (usage) {
          recordImport({
            id: crypto.randomUUID(), reqCtx, status: 'failed', row, usage, sourceKind: input.kind, sourceUrl: input.sourceUrl,
            summary: { ...summaryBase, continued: true, error: 'client_aborted' },
          });
        }
      } else {
        const timeout = e && (e.name === 'IdleTimeoutError' || e.name === 'TimeoutError');
        const message = e && e.name === 'TimeoutError' ? `识别超过 ${Math.round(totalMs / 1000)} 秒，已停止` : ctx.ai.friendly(e, use.apiKey);
        log.warn('import', `识别失败 ${row.kind}/${row.model}: ${message}`);
        sse.send('error', { code: timeout ? 'ai_timeout' : 'ai_upstream', message });
      }
    } finally {
      res.off('close', onClose);
      sse.close();
    }
  }

  // —— 从流水识别（kind=transactions）——

  /** 查询参数、请求体里的 months：1–24，默认 13。 */
  const monthsOf = (raw) => (v.isMissing(raw) || raw === '' ? detect.DEFAULT_MONTHS : v.int(raw, 'months', { min: 1, max: detect.MAX_MONTHS }));

  /**
   * 最近 [months] 个月的确认支出 + 没归档的卡 + 关联了流水的物品 → 候选分组（全部、排好序）。candidates 和 extract 共用这一份。
   * 物品那条和 charge_hints 的口径一样：是哪件物品的购买流水，这笔就算已关联（不默认勾，导入时也不拿它当卡的上次扣费）。
   */
  function detectGroups(months) {
    const today = v.localDay();
    const from = perks.addPeriod(today, 'month', -months);
    const txs = db.all(detect.CANDIDATE_TX_SQL, detect.MIN_CENTS, detect.MAX_CENTS, from, perks.addDays(today, 1));
    const cards = db.all(
      'SELECT id, name, pay_pattern, last_charge_tx_id FROM memberships WHERE deleted_at IS NULL AND archived = 0' +
        ' AND (pay_pattern IS NOT NULL OR last_charge_tx_id IS NOT NULL) ORDER BY sort_order, created_at, id',
    );
    const assets = db.all('SELECT id, name, transaction_id FROM assets WHERE deleted_at IS NULL AND transaction_id IS NOT NULL ORDER BY created_at, id');
    return { today, from, groups: detect.detectSubscriptions(txs, { today, months, cards, assets }) };
  }

  /** GET /asset-import/candidates?months=13 → {months, from, today, total, items:[前 40 组]}。 */
  function candidates(req, res, reqCtx) {
    const months = monthsOf(reqCtx.query.months);
    const { today, from, groups } = detectGroups(months);
    sendJson(res, 200, { months, from, today, total: groups.length, items: groups.slice(0, detect.MAX_GROUPS) });
  }

  async function fromTransactions(res, reqCtx, b) {
    if (!v.isMissing(b.targetMembershipId) && b.targetMembershipId !== '') {
      v.bad('targetMembershipId', '从流水识别出来的是会员卡，不能归到一张卡下');
    }
    const keys = [...new Set(v.list(b.groups, 'groups', { max: detect.MAX_GROUPS, required: true }).map((k) => v.str(k, 'groups', { max: 40 })))];
    if (!keys.length) v.bad('groups', '至少勾一组');
    const months = monthsOf(b.months);
    const useAi = v.isMissing(b.useAi) ? false : v.bool(b.useAi, 'useAi');
    const byKey = new Map(detectGroups(months).groups.map((g) => [g.key, g]));
    const picked = keys.map((k) => byKey.get(k)).filter(Boolean);
    if (!picked.length) throw new HttpError(409, 'groups_stale', '勾的这几组和现在的流水对不上了（刚记了新流水？），回去刷新一下再选');
    const notices = picked.length < keys.length ? [`有 ${keys.length - picked.length} 组和现在的流水对不上了（刚记了新流水？），没算进来`] : [];
    if (!useAi) {
      // 「直接生成」：不调模型、不要渠道、不占限流；照样走 SSE，App 的进度页和别的来源一个样。
      const sse = openSse(res);
      try {
        sse.send('stage', { stage: 'matching', message: `正在按商户名生成 ${picked.length} 张卡…` });
        finishTransactions(sse, reqCtx, { picked, notices, names: new Map(), row: null, usage: null, useAi: false });
      } finally {
        sse.close();
      }
      return;
    }
    // 先挑渠道（没有渠道 400，不占限流），再过限流闸门。
    const row = ctx.ai.pickProvider(b.providerId);
    const memberId = reqCtx.member.id;
    if (running.has(memberId)) throw new HttpError(409, 'import_in_progress', '你还有一次识别没结束，等它结束或取消后再试');
    running.add(memberId);
    try {
      ctx.ai.takeToken(reqCtx);
      if (!hourly.allow(memberId)) {
        log.warn('import', `成员 ${reqCtx.member.username} 触发导入限流（${perHour}/h）`);
        throw new HttpError(429, 'rate_limited', `识别太频繁了（每小时最多 ${perHour} 次），过一会儿再试`);
      }
      await ctx.ai.withStreamSlot(() => nameGroups(res, reqCtx, row, { picked, notices }));
    } finally {
      running.delete(memberId);
    }
  }

  /**
   * 「AI 整理名称」：只发规范化商户、金额、周期、次数（商户名来自备注的组发占位名，模型给的名字也不收）；模型没按格式写、
   * 只写了一部分，没起名的组按商户名。
   */
  async function nameGroups(res, reqCtx, row, { picked, notices }) {
    const use = ctx.ai.toUse(row);
    const prompt = subs.buildNamingPrompt(picked);
    const noteOnly = picked.filter((g) => g.fromNote).length;
    const namable = picked.length - noteOnly;
    if (noteOnly) notices.push(`有 ${noteOnly} 组没填商户名（名字是从备注来的），备注不发给 AI，这几组按备注开头生成，导入前可以改`);
    const maxTokens = Number.isInteger(use.extra.importMaxTokens) ? use.extra.importMaxTokens : subs.NAMING_MAX_TOKENS;
    log.info('import', `整理名称 ${row.kind}/${row.model} ${picked.length} 组 发送 ${prompt.user.length} 字`);
    log.debug('import', `分组=${prompt.user}`);
    const sse = openSse(res);
    const ctl = new AbortController();
    const onClose = () => ctl.abort();
    res.on('close', onClose);
    const started = Date.now();
    try {
      sse.send('stage', { stage: 'asking', message: `正在请模型整理 ${picked.length} 组的名称…` });
      const counter = createRecordCounter();
      let seen = 0;
      const out = await providers.streamChat(
        use,
        { system: prompt.system, messages: [{ role: 'user', content: prompt.user }], maxTokens, signal: ctl.signal, timeoutMs: totalMs, idleMs },
        (delta) => {
          const n = counter.push(delta);
          if (n > seen) {
            seen = n;
            sse.send('record', { n });
          }
        },
      );
      const usage = { input: out.usage.input || 0, output: out.usage.output || 0 };
      const parsed = parseImportOutput(out.text);
      const names = parsed.ok ? subs.namesFromOutput(parsed.records, picked) : new Map();
      if (!parsed.ok) notices.push('模型没有按要求整理名称，已按商户名直接生成');
      else if (names.size < namable) notices.push(`模型只整理了 ${names.size} 组的名称，其余按商户名`);
      sse.send('stage', { stage: 'matching', message: '正在和账本里已有的对一对…' });
      finishTransactions(sse, reqCtx, { picked, notices, names, row, usage, useAi: true, stopReason: out.stopReason, aiError: parsed.ok ? null : 'ai_bad_output' });
      log.info('import', `整理名称完成 ${row.kind}/${row.model} ${names.size}/${picked.length} 组 token ${usage.input}/${usage.output} ${Date.now() - started}ms`);
    } catch (e) {
      if (ctl.signal.aborted) {
        log.debug('import', `客户端断开，已中止上游 ${row.kind}/${row.model}（${Date.now() - started}ms）`);
      } else {
        const timeout = e && (e.name === 'IdleTimeoutError' || e.name === 'TimeoutError');
        const message = e && e.name === 'TimeoutError' ? `整理名称超过 ${Math.round(totalMs / 1000)} 秒，已停止` : ctx.ai.friendly(e, use.apiKey);
        log.warn('import', `整理名称失败 ${row.kind}/${row.model}: ${message}`);
        sse.send('error', { code: timeout ? 'ai_timeout' : 'ai_upstream', message });
      }
    } finally {
      res.off('close', onClose);
      sse.close();
    }
  }

  /** 勾选的分组（+ 模型给的名字）→ 草稿：拼 records、规范化、比对，记一行 ai_imports，发 done。 */
  function finishTransactions(sse, reqCtx, { picked, notices, names, row, usage, useAi, stopReason = null, aiError = null }) {
    const draft = normalizeImport(subs.recordsFromGroups(picked, names), { want: 'virtual', sourceKind: 'transactions', today: v.localDay() });
    matchImport(db, draft);
    const importId = crypto.randomUUID();
    recordImport({
      id: importId, reqCtx, status: 'extracted', row, usage, sourceKind: 'transactions',
      summary: { want: 'virtual', sourceKind: 'transactions', groups: picked.length, useAi, named: names.size, stopReason, aiError, counts: counts(draft) },
    });
    sse.send('done', {
      importId,
      draft: {
        ...draft, importId, want: 'virtual', truncated: false, continued: false, continueFailed: false, salvaged: false, notices,
        targetMembershipId: null,
        source: { kind: 'transactions', groups: picked.length },
        providerId: row ? row.id : null, model: row ? row.model : null, usage: usage || { input: 0, output: 0 },
      },
    });
  }

  // —— 网址（先抓正文）——

  /**
   * POST /asset-import/fetch {url} → {url, finalUrl, title, text, chars, truncated, hint, message}（lib/page_fetch.js）。
   * 网址写法不对先 400（不占限流）；每人每分钟 URL_FETCH_PER_MIN 次。PDF、登录墙、正文太短照样 200，hint 说明。
   */
  async function fetchUrl(req, res, reqCtx) {
    if (allowFakeIp && reqCtx.member.role !== 'admin') {
      throw new HttpError(403, 'url_fetch_admin_only',
        '服务端放开了 fake-ip 抓取，这时核实不了网址的真实目标地址，所以网址导入只有管理员能用。可以先改用截图或粘贴。');
    }
    const b = v.body(reqCtx.body);
    const target = pageFetch.parseTarget(b.url, 'url');
    if (!fetches.allow(reqCtx.member.id)) {
      log.warn('import', `成员 ${reqCtx.member.username} 触发抓网页限流（${fetchPerMin}/min）`);
      throw new HttpError(429, 'rate_limited', `抓网页太频繁了（每分钟最多 ${fetchPerMin} 次），过一会儿再试`);
    }
    const started = Date.now();
    try {
      const page = await pageFetch.fetchPage(target.href, { allowFakeIp, timeoutMs: fetchTimeoutMs });
      log.info('import', `抓网页 ${page.chars} 字 hint=${page.hint || '-'} ${Date.now() - started}ms`);
      log.debug('import', `抓网页 ${target.href} → ${page.finalUrl}`);
      sendJson(res, 200, page);
    } catch (e) {
      if (e instanceof HttpError) log.info('import', `抓网页失败 ${e.code} ${Date.now() - started}ms`);
      // 被拦时解析出的地址不回给客户端（不给成员借服务端的 DNS 查内网主机），只进 debug。
      if (e && e.blockedAddress) log.debug('import', `抓网页被拦 ${target.href} → ${e.blockedAddress}`);
      throw e;
    }
  }

  function apply(req, res, reqCtx) {
    const body = v.body(reqCtx.body);
    const clientId = v.str(body.clientId, 'clientId', { max: 64 });
    const hit = idem.lookup(db, 'asset_import.apply', clientId);
    if (hit && hit.response) {
      // 重放也先核对是不是本人发起的那次（refId 就是 importId）：别人的 clientId 撞上了也拿不到结果。
      const mine = db.get('SELECT member_id, status FROM ai_imports WHERE id = ?', hit.refId);
      if (mine && mine.member_id !== reqCtx.member.id) throw new HttpError(403, 'forbidden', '这批识别结果不是你发起的');
      // 撤销过的不能再回「导入成功」：App 拿旧草稿重发时要知道那批已经没了。
      if (mine && mine.status === 'undone') throw new HttpError(409, 'import_undone', '这批导入已经撤销了；要再导得重新识别一次');
      return sendJson(res, 200, { ...hit.response, replayed: true });
    }
    const importId = v.str(body.importId, 'importId', { max: 64 });
    const row = db.get('SELECT * FROM ai_imports WHERE id = ?', importId);
    if (!row) throw new HttpError(404, 'not_found', '这批识别结果不在了（超过 90 天会清掉），重新识别一次吧');
    if (row.member_id !== reqCtx.member.id) throw new HttpError(403, 'forbidden', '这批识别结果不是你发起的');
    if (row.status === 'undone') throw new HttpError(409, 'import_undone', '这批导入已经撤销了；要再导得重新识别一次');
    if (row.status !== 'extracted') throw new HttpError(409, 'import_used', '这批识别结果已经导入过了');
    const out = applyImport({ db, ctx, body, reqCtx, importRow: row, clientId });
    log.info('import', `导入 ${importId} by ${reqCtx.member.username}：${JSON.stringify(out.created)}`);
    sendJson(res, 200, out);
  }

  /** 整批撤销：7 天内、本人或管理员；撤销过的再来原样回上次的结果（回应丢了 App 重发也不报错）。 */
  function undo(req, res, reqCtx) {
    const row = db.get('SELECT * FROM ai_imports WHERE id = ?', reqCtx.params.id);
    if (!row) throw new HttpError(404, 'not_found', '这批导入的记录不在了（超过 90 天会清掉）');
    if (row.member_id !== reqCtx.member.id && reqCtx.member.role !== 'admin') {
      throw new HttpError(403, 'forbidden', '只有发起这次导入的人或管理员能撤销');
    }
    if (row.status === 'undone') {
      let prev = null;
      try {
        prev = JSON.parse(row.summary || '{}').undone;
      } catch {
        prev = null;
      }
      return sendJson(res, 200, { ...(prev || { importId: row.id }), replayed: true });
    }
    if (row.status !== 'applied') throw new HttpError(409, 'import_not_applied', '这批识别结果还没导入，没有可撤销的');
    if (!row.applied_at || Date.now() - Date.parse(row.applied_at) > UNDO_DAYS * 86400000) {
      throw new HttpError(409, 'undo_expired', `导入超过 ${UNDO_DAYS} 天了，不能整批撤销；要改就去对应的卡、物品里逐条改`);
    }
    const out = undoImport({ db, ctx, importRow: row, reqCtx });
    log.info(
      'import',
      `撤销导入 ${row.id} by ${reqCtx.member.username}：删 ${JSON.stringify(out.undone)} 恢复 ${JSON.stringify(out.restored)}` +
        ` 别名 ${out.aliasesRemoved} 跳过 ${out.skippedChanged.length}/${out.skippedInUse.length}`,
    );
    sendJson(res, 200, out);
  }

  /**
   * 7 天内导入了、还没撤销的（App「最近的 AI 导入」）：本人发起的；管理员看全家的。新的在前，最多 50 条。
   * 每条 {importId, memberId, memberName, mine, sourceKind, createdAt, appliedAt, created, updated, daysLeft}：
   * created / updated 是导入时的计数（和 apply 回应的一样），daysLeft 是还能撤几天（不足一天算 1 天）。
   */
  function recent(req, res, reqCtx) {
    const me = reqCtx.member;
    const admin = me.role === 'admin';
    const nowMs = Date.now();
    const since = new Date(nowMs - UNDO_DAYS * 86400000).toISOString();
    const rows = db.all(
      'SELECT i.id, i.member_id, i.created_at, i.applied_at, i.source_kind, i.summary, m.display_name AS member_name' +
        ' FROM ai_imports i LEFT JOIN members m ON m.id = i.member_id' +
        ` WHERE i.status = 'applied' AND i.applied_at >= ?${admin ? '' : ' AND i.member_id = ?'}` +
        ' ORDER BY i.applied_at DESC LIMIT 50',
      since, ...(admin ? [] : [me.id]),
    );
    const items = rows
      .map((r) => {
        const left = Date.parse(r.applied_at) + UNDO_DAYS * 86400000 - nowMs;
        let applied = {};
        try {
          applied = JSON.parse(r.summary || '{}').applied || {};
        } catch {
          applied = {};
        }
        return {
          importId: r.id,
          memberId: r.member_id,
          memberName: r.member_name ?? null,
          mine: r.member_id === me.id,
          sourceKind: r.source_kind || 'text',
          createdAt: r.created_at,
          appliedAt: r.applied_at,
          created: applied.created || {},
          updated: applied.updated || {},
          left,
        };
      })
      .filter((x) => x.left > 0)
      .map(({ left, ...x }) => ({ ...x, daysLeft: Math.max(1, Math.ceil(left / 86400000)) }));
    sendJson(res, 200, { items });
  }

  log.debug('import', `导入限流 ${perHour}/h/人，空闲超时 ${idleMs}ms，总时长 ${totalMs}ms；抓网页 ${fetchPerMin}/min/人，fake-ip ${allowFakeIp ? '放开' : '拦截'}`);
  if (allowFakeIp) log.warn('import', `已放开 fake-ip 抓取（URL_FETCH_ALLOW_FAKEIP=1）：${pageFetch.FAKE_IP_COST}`);

  return {
    name: 'asset_import',
    routes: [
      { method: 'POST', pattern: '/asset-import/extract', handler: extract, maxBody: EXTRACT_MAX_BODY },
      { method: 'POST', pattern: '/asset-import/apply', handler: apply, maxBody: APPLY_MAX_BODY },
      { method: 'POST', pattern: '/asset-import/:id/undo', handler: undo, maxBody: 4096 },
      { method: 'GET', pattern: '/asset-import/recent', handler: recent },
      { method: 'GET', pattern: '/asset-import/candidates', handler: candidates },
      { method: 'POST', pattern: '/asset-import/fetch', handler: fetchUrl, maxBody: FETCH_MAX_BODY },
    ],
  };
};
