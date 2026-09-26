'use strict';

// AI 智能导入（spec §4、§6）：虚拟资产（平台 → 会员/卡 → 权益）和实物共用一条管线，先抽出可编辑的预览，确认后才落库。
//
//   POST /asset-import/extract   SSE：stage → record*（已识别 N 条）→ done{importId, draft} | error{code, message}
//   POST /asset-import/apply     单个事务落库（lib/perk_import_apply.js），只增改、不删
//
// 本阶段只接 kind=text（粘贴文字）；image / url / transactions 在 P5 / P7 接进来，这里先回 400 kind_unsupported。
//
// 花钱的闸门（除了 ai.js 的每人每分钟和并发流名额）：
//   · 每人每小时 AI_IMPORT_PER_HOUR 次（默认 20），超了 429 rate_limited；
//   · 每人同时只能有 1 个导入在跑，第二个 409 import_in_progress（名额在 finally 里还，客户端半路跑了也照还）；
//   · 60 秒没收到新数据算超时（AI_IMPORT_IDLE_MS），整次导入最长 300 秒（AI_IMPORT_TOTAL_MS）—— 两个变量只给测试调小。
//
// 日志：info 只记长度和用量；原文只进 debug。发给模型前先脱敏（手机号打码、卡号只留尾号，lib/redact.js）。

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
const { buildImportPrompt, IMPORT_MAX_TOKENS, MAX_EXISTING } = require('../lib/perk_import_prompt');
const { applyImport } = require('../lib/perk_import_apply');

const providers = require('./ai_providers');

const KINDS = ['text', 'image', 'url', 'transactions'];
const WANTS = ['auto', 'virtual', 'items'];
const MAX_TEXT = 20000;
const EXTRACT_MAX_BODY = 8 * 1024 * 1024;
const APPLY_MAX_BODY = 1024 * 1024;
const KEEP_DAYS = 90;

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

  /** 记一行用量（extract 结束时；用户最后没导入也有记录），顺手清掉 90 天前的。 */
  function recordImport({ id, reqCtx, status, row, usage, summary }) {
    const now = db.now();
    db.tx(() => {
      db.run(
        'INSERT INTO ai_imports(id, member_id, created_at, status, source_kind, provider_id, model, usage_in, usage_out, summary)' +
          " VALUES(?, ?, ?, ?, 'text', ?, ?, ?, ?, ?)",
        id, reqCtx.member.id, now, status, row.id, row.model, usage.input || 0, usage.output || 0, JSON.stringify(summary),
      );
      db.run('DELETE FROM ai_imports WHERE created_at < ?', new Date(Date.now() - KEEP_DAYS * 86400000).toISOString());
    });
  }

  async function extract(req, res, reqCtx) {
    const b = v.body(reqCtx.body);
    const kind = b.kind === undefined || b.kind === null ? 'text' : v.enumOf(b.kind, 'kind', KINDS);
    if (kind !== 'text') throw new HttpError(400, 'kind_unsupported', '这个版本只支持粘贴文字导入，截图、网址、从流水识别还在路上');
    const want = b.want === undefined || b.want === null ? 'auto' : v.enumOf(b.want, 'want', WANTS);
    const raw = v.str(b.text, 'text', { max: MAX_TEXT, trim: false });
    if (!raw.trim()) v.bad('text', '先粘点东西进来');
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
      const row = ctx.ai.pickProvider(b.providerId);
      await ctx.ai.withStreamSlot(() => run(res, reqCtx, row, { raw, want, target }));
    } finally {
      running.delete(memberId);
    }
  }

  async function run(res, reqCtx, row, { raw, want, target }) {
    const use = ctx.ai.toUse(row);
    const picked = pickParagraphs(raw);
    const { text: source, phones, cards } = redactPii(picked.text);
    const prompt = buildImportPrompt({ want, existing: existingNames(), target: target && { name: target.name, platform: target.platform } });
    const maxTokens = Number.isInteger(use.extra.importMaxTokens) ? use.extra.importMaxTokens : IMPORT_MAX_TOKENS;
    const notices = [];
    if (picked.picked) notices.push(`材料有 ${raw.length} 字，只挑了最相关的 ${picked.kept} 段（约 ${source.length} 字）`);
    log.info('import', `识别 ${row.kind}/${row.model} 原文 ${raw.length} 字 发送 ${source.length} 字 want=${want} 打码 ${phones}/${cards}`);
    log.debug('import', `原文=${source}`);

    const sse = openSse(res);
    const ctl = new AbortController();
    const onClose = () => ctl.abort();
    res.on('close', onClose);
    const started = Date.now();
    try {
      sse.send('stage', { stage: 'asking', message: notices[0] || '正在请模型识别…' });
      const counter = createRecordCounter();
      let seen = 0;
      const out = await providers.streamChat(
        use,
        { system: prompt.system, messages: [{ role: 'user', content: prompt.user(source) }], maxTokens, signal: ctl.signal, timeoutMs: totalMs, idleMs },
        (delta) => {
          const n = counter.push(delta);
          if (n > seen) {
            seen = n;
            sse.send('record', { n });
          }
        },
      );
      sse.send('stage', { stage: 'matching', message: '正在和账本里已有的对一对…' });
      const parsed = parseImportOutput(out.text);
      const summaryBase = { want, textLength: raw.length, sentLength: source.length, stopReason: out.stopReason };
      if (!parsed.ok) {
        recordImport({ id: crypto.randomUUID(), reqCtx, status: 'failed', row, usage: out.usage, summary: { ...summaryBase, error: 'ai_bad_output' } });
        log.warn('import', `模型输出解析不了（${out.text.length} 字，stop=${out.stopReason}）`);
        const refused = out.stopReason === 'refusal';
        sse.send('error', {
          code: refused ? 'ai_refusal' : 'ai_bad_output',
          message: refused ? '模型拒绝处理这段材料，换个渠道或删掉敏感内容再试' : '模型没有按要求返回结果，换个渠道或把材料删短一点再试',
        });
        return;
      }
      const truncated = out.stopReason === 'max_tokens' || !parsed.done;
      if (truncated) notices.push('材料太长，模型只写了一部分；预览里的是已经收到的，剩下的建议分段再导一次');
      const draft = normalizeImport(parsed.records, { want, source, sourceKind: 'text', today: v.localDay(), target });
      matchImport(db, draft);
      if (!parsed.records.length) notices.push('材料里没找到会员、权益或买的东西');
      const importId = crypto.randomUUID();
      recordImport({
        id: importId, reqCtx, status: 'extracted', row, usage: out.usage,
        summary: { ...summaryBase, counts: counts(draft), truncated, salvaged: parsed.salvaged, dropped: draft.dropped },
      });
      sse.send('done', {
        importId,
        draft: {
          ...draft, importId, want, truncated, salvaged: parsed.salvaged, notices,
          targetMembershipId: target ? target.id : null,
          source: { kind: 'text', text: source },
          providerId: row.id, model: row.model, usage: out.usage,
        },
      });
      log.info(
        'import',
        `识别完成 ${row.kind}/${row.model} ${parsed.records.length} 条（截断 ${truncated}，抢救 ${parsed.salvaged}） token ${out.usage.input}/${out.usage.output} ${Date.now() - started}ms`,
      );
    } catch (e) {
      if (ctl.signal.aborted) {
        log.debug('import', `客户端断开，已中止上游 ${row.kind}/${row.model}（${Date.now() - started}ms）`);
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

  function apply(req, res, reqCtx) {
    const body = v.body(reqCtx.body);
    const clientId = v.str(body.clientId, 'clientId', { max: 64 });
    const hit = idem.lookup(db, 'asset_import.apply', clientId);
    if (hit && hit.response) {
      // 重放也先核对是不是本人发起的那次（refId 就是 importId）：别人的 clientId 撞上了也拿不到结果。
      const mine = db.get('SELECT member_id FROM ai_imports WHERE id = ?', hit.refId);
      if (mine && mine.member_id !== reqCtx.member.id) throw new HttpError(403, 'forbidden', '这批识别结果不是你发起的');
      return sendJson(res, 200, { ...hit.response, replayed: true });
    }
    const importId = v.str(body.importId, 'importId', { max: 64 });
    const row = db.get('SELECT * FROM ai_imports WHERE id = ?', importId);
    if (!row) throw new HttpError(404, 'not_found', '这批识别结果不在了（超过 90 天会清掉），重新识别一次吧');
    if (row.member_id !== reqCtx.member.id) throw new HttpError(403, 'forbidden', '这批识别结果不是你发起的');
    if (row.status !== 'extracted') throw new HttpError(409, 'import_used', '这批识别结果已经导入过了');
    const out = applyImport({ db, ctx, body, reqCtx, importRow: row, clientId });
    log.info('import', `导入 ${importId} by ${reqCtx.member.username}：${JSON.stringify(out.created)}`);
    sendJson(res, 200, out);
  }

  log.debug('import', `导入限流 ${perHour}/h/人，空闲超时 ${idleMs}ms，总时长 ${totalMs}ms`);

  return {
    name: 'asset_import',
    routes: [
      { method: 'POST', pattern: '/asset-import/extract', handler: extract, maxBody: EXTRACT_MAX_BODY },
      { method: 'POST', pattern: '/asset-import/apply', handler: apply, maxBody: APPLY_MAX_BODY },
    ],
  };
};
