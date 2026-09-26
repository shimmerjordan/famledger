'use strict';

// AI 上游适配器。**导出对象 → 装载器跳过它**（只有 ai.js 是模块工厂）。
//
// 两种协议，一个出口：
//
//   anthropic  POST {baseUrl}/v1/messages        x-api-key + anthropic-version
//   openai     POST {baseUrl}/chat/completions   Authorization: Bearer
//              （baseUrl 自带 /v1，所以这里不再补）
//
//   streamChat(provider, {system, messages, maxTokens, signal, timeoutMs, idleMs}, onDelta)
//       → {text, usage:{input, output}, stopReason}      边收边喂 onDelta
//   complete (provider, {system, messages, maxTokens, json})
//       → {text, usage, stopReason}                      test / classify 用
//
// provider = {kind, baseUrl, model, apiKey, extra}（apiKey 已解密；Ollama 可以是空；extra 是渠道的 extra 对象）。
//
// stopReason 两家统一成四种：end（正常说完）/ max_tokens（写到上限被截断）/ refusal（拒答或被内容审核拦下）/
// other（别的原因，或上游压根没说 —— 国产兼容端和 cc-trans 未必透传结束原因）。
//
// 消息的 content 可以是字符串，也可以是「中性块」数组：`{type:'text', text}`、`{type:'image', mediaType, data}`
// （data 是 base64，不带 data: 前缀）。bodyFor 按渠道转换：anthropic 的图放在文字前面（官方建议），
// openai 用 data URL 并显式带 `detail:'high'`（不写的话有的兼容端按 low 处理，长截图的小字就糊了）。
//
// SSE 解析故意做得笨而稳：按字节流解码（TextDecoder stream 模式，一个汉字被 TCP
// 切成两片也不会乱码）、按行切、只认 `data:`，事件类型一律从 payload 的 type 字段
// 读（`event:` 行有的上游根本不发）。注释行、`ping`、认不出来的 JSON 一律跳过 ——
// 上游多发点什么不该把整条流搞崩。

const KINDS = ['anthropic', 'openai'];
const TIMEOUT_MS = 120000;
const DEFAULT_MAX_TOKENS = 2048;
const SNIPPET = 300;
const STOP_REASONS = ['end', 'max_tokens', 'refusal', 'other'];

/**
 * 渠道 extra.requestExtras 里允许注入请求体顶层的键（白名单）。model / messages / stream / max_tokens / system
 * 这些协议骨架永远不能被覆盖；别的键存的时候就拒掉（ai.js readWrite），这里再滤一遍兜底。
 */
const REQUEST_EXTRA_KEYS = [
  'temperature',
  'top_p',
  'top_k',
  'presence_penalty',
  'frequency_penalty',
  'seed',
  'reasoning_effort',
  'enable_thinking',
  'thinking',
  'chat_template_kwargs',
  'service_tier',
];

/** 上游的锅（4xx/5xx、流里的 error 事件）。调用方据此回 `{ok:false}` 或 SSE error。 */
class UpstreamError extends Error {
  constructor(status, snippet) {
    super(`上游返回 ${status}${snippet ? `：${snippet}` : ''}`);
    this.name = 'UpstreamError';
    this.status = status;
    this.snippet = snippet || '';
  }
}

/** 预设渠道。客户端拿去一键填表，服务端不存、不认证、跟数据库无关。 */
const PRESETS = [
  {
    key: 'cc-trans',
    name: 'cc-trans（自建 Anthropic 反代）',
    kind: 'anthropic',
    baseUrl: 'http://nas:8787',
    model: 'claude-sonnet-5',
    hint: '填 cc-trans 下发的 cct- 客户端令牌；地址是你的 cc-trans 服务，例如 http://nas:8787',
  },
  { key: 'siliconflow', name: '硅基流动', kind: 'openai', baseUrl: 'https://api.siliconflow.cn/v1', model: 'Qwen/Qwen3-32B', hint: '在硅基流动控制台「API 密钥」里新建，sk- 开头' },
  { key: 'deepseek', name: 'DeepSeek 深度求索', kind: 'openai', baseUrl: 'https://api.deepseek.com/v1', model: 'deepseek-chat', hint: '在 platform.deepseek.com 的 API keys 页面新建' },
  { key: 'moonshot', name: '月之暗面 Kimi', kind: 'openai', baseUrl: 'https://api.moonshot.cn/v1', model: 'kimi-k2-0711-preview', hint: '在 platform.moonshot.cn 的「API Key 管理」新建' },
  { key: 'zhipu', name: '智谱 GLM', kind: 'openai', baseUrl: 'https://open.bigmodel.cn/api/paas/v4', model: 'glm-4.5', hint: '在 bigmodel.cn 控制台「API Keys」复制' },
  { key: 'openai', name: 'OpenAI 官方', kind: 'openai', baseUrl: 'https://api.openai.com/v1', model: 'gpt-5-mini', hint: '需要能直连 api.openai.com；国内一般要走反代' },
  { key: 'anthropic', name: 'Anthropic 官方', kind: 'anthropic', baseUrl: 'https://api.anthropic.com', model: 'claude-sonnet-5', hint: '需要能直连 api.anthropic.com；国内一般要走反代' },
  { key: 'ollama', name: 'Ollama（本机模型）', kind: 'openai', baseUrl: 'http://host.docker.internal:11434/v1', model: 'qwen3:8b', hint: '本机跑的 Ollama 不需要密钥；容器里要用 host.docker.internal 才找得到宿主机' },
];

/** 流式时这么久没收到任何新数据：上游挂住了（见 streamChat 的 idleMs）。 */
class IdleTimeoutError extends Error {
  constructor(ms) {
    super(`上游 ${Math.round(ms / 1000)} 秒没有新数据`);
    this.name = 'IdleTimeoutError';
    this.ms = ms;
  }
}

const LOCAL_HOSTS = new Set(['localhost', '127.0.0.1', '::1', '[::1]', '0.0.0.0', 'host.docker.internal', 'host.containers.internal']);

/** 本机/宿主机地址上的服务（Ollama、同机 LM Studio）可以没有密钥。 */
function isLocalHost(baseUrl) {
  try {
    const h = new URL(baseUrl).hostname.toLowerCase();
    return LOCAL_HOSTS.has(h) || h.startsWith('127.') || h.endsWith('.local');
  } catch {
    return false;
  }
}

/** `http(s)://…`，去掉末尾斜杠。不是合法 URL 就返回 null，由调用方报 400。 */
function normalizeBaseUrl(raw) {
  if (typeof raw !== 'string') return null;
  const s = raw.trim().replace(/\/+$/, '');
  if (!s) return null;
  let u;
  try {
    u = new URL(s);
  } catch {
    return null;
  }
  if (u.protocol !== 'http:' && u.protocol !== 'https:') return null;
  return s;
}

const cut = (s) => String(s == null ? '' : s).replace(/\s+/g, ' ').slice(0, SNIPPET);

/** 超时永远在（默认 120 秒，导入传 300 秒），客户端断线的 signal 叠加上去。 */
function signalFor(extra, timeoutMs = TIMEOUT_MS) {
  const timeout = AbortSignal.timeout(timeoutMs);
  return extra ? AbortSignal.any([timeout, extra]) : timeout;
}

/** 渠道 extra 里「看不看得了图」：只有明确测出来 `vision === false` 的才算不行（P5 的看图探测写这个字段）。 */
function visionOk(extra) {
  return !(extra && typeof extra === 'object' && extra.vision === false);
}

/** 两家的结束原因原话 → 四种之一；没给就是 other。 */
function stopReasonOf(kind, raw) {
  if (raw === undefined || raw === null || raw === '') return 'other';
  if (kind === 'anthropic') {
    if (raw === 'end_turn' || raw === 'stop_sequence') return 'end';
    if (raw === 'max_tokens') return 'max_tokens';
    if (raw === 'refusal') return 'refusal';
    return 'other';
  }
  if (raw === 'stop') return 'end';
  if (raw === 'length') return 'max_tokens';
  if (raw === 'content_filter') return 'refusal';
  return 'other';
}

/** 渠道 extra.requestExtras 里白名单内的键（值原样）；没有或不是对象 → 空。 */
function requestExtrasOf(provider) {
  const raw = provider && provider.extra && provider.extra.requestExtras;
  if (!raw || typeof raw !== 'object' || Array.isArray(raw)) return {};
  const out = {};
  for (const k of REQUEST_EXTRA_KEYS) if (raw[k] !== undefined) out[k] = raw[k];
  return out;
}

/**
 * 一条消息的 content → 这家协议的形状。字符串原样（对话、分类都是这种，行为不变）；中性块数组按上面的规矩转。
 * 不认识的块丢掉。
 */
function contentFor(kind, content) {
  if (!Array.isArray(content)) return content;
  const texts = [];
  const images = [];
  for (const b of content) {
    if (b && b.type === 'text' && typeof b.text === 'string') texts.push(b);
    else if (b && b.type === 'image' && typeof b.data === 'string') images.push(b);
  }
  if (kind === 'anthropic') {
    return [
      ...images.map((b) => ({ type: 'image', source: { type: 'base64', media_type: b.mediaType || 'image/png', data: b.data } })),
      ...texts.map((b) => ({ type: 'text', text: b.text })),
    ];
  }
  return [
    ...texts.map((b) => ({ type: 'text', text: b.text })),
    ...images.map((b) => ({ type: 'image_url', image_url: { url: `data:${b.mediaType || 'image/png'};base64,${b.data}`, detail: 'high' } })),
  ];
}

function endpoint(provider) {
  const base = String(provider.baseUrl || '').replace(/\/+$/, '');
  return provider.kind === 'anthropic' ? `${base}/v1/messages` : `${base}/chat/completions`;
}

function headersFor(provider, stream) {
  const h = { 'content-type': 'application/json', accept: stream ? 'text/event-stream' : 'application/json' };
  if (provider.kind === 'anthropic') {
    h['anthropic-version'] = '2023-06-01';
    if (provider.apiKey) h['x-api-key'] = provider.apiKey;
  } else if (provider.apiKey) {
    h.authorization = `Bearer ${provider.apiKey}`;
  }
  return h;
}

/**
 * 请求体。anthropic 的 system 是顶层字段，openai 的 system 是第一条消息 —— 这是
 * 两个协议唯一真正的形状差异。
 *
 * `altMax` = 用 `max_completion_tokens` 代替 `max_tokens`。OpenAI 的 gpt-5 / o 系列
 * 只认前者，而硅基流动 / DeepSeek / 月之暗面 / 智谱 / Ollama 只认后者 —— 没有一个
 * 字段是两边都收的，所以默认发老字段（覆盖面更大），被 400 顶回来再换（见 §重试）。
 */
function bodyFor(provider, { system, messages, maxTokens, json }, stream, altMax = false) {
  const max = Number.isFinite(maxTokens) && maxTokens > 0 ? Math.trunc(maxTokens) : DEFAULT_MAX_TOKENS;
  const clean = (messages || []).map((m) => ({ role: m.role, content: contentFor(provider.kind, m.content) }));
  // 白名单参数先铺底，协议骨架后写：就算白名单哪天放错了键，也盖不掉 model / messages / max_tokens。
  const extras = requestExtrasOf(provider);
  if (provider.kind === 'anthropic') {
    // Anthropic 没有 max_completion_tokens 这个字段，永远是 max_tokens。
    const body = { ...extras, model: provider.model, max_tokens: max, messages: clean };
    if (system) body.system = system;
    if (stream) body.stream = true;
    return body;
  }
  const body = {
    ...extras,
    model: provider.model,
    messages: system ? [{ role: 'system', content: system }, ...clean] : clean,
    ...(altMax ? { max_completion_tokens: max } : { max_tokens: max }),
  };
  if (stream) {
    body.stream = true;
    body.stream_options = { include_usage: true };
  } else if (json) {
    // OpenAI 兼容端的 JSON 模式。不支持的上游会 400，见 complete() 里的退一步重试。
    body.response_format = { type: 'json_object' };
  }
  return body;
}

/**
 * 上游在说「别发 max_tokens，发 max_completion_tokens」吗？
 * gpt-5 / o 系列的原话：Unsupported parameter: 'max_tokens' is not supported with
 * this model. Use 'max_completion_tokens' instead.
 */
function needsAltMaxTokens(e) {
  return e instanceof UpstreamError && e.status === 400 && String(e.snippet || '').includes('max_completion_tokens');
}

/**
 * 上游 400 并且说了 max_tokens 的合法上限吗？说了就回那个上限，没说回 null。认这几种原话：
 *   Anthropic         max_tokens: 64001 > 64000, which is the maximum allowed number of output tokens for …
 *   DeepSeek 等        Invalid max_tokens value, the valid range of max_tokens is [1, 8192]
 *   其他兼容端         max_tokens must be less than or equal to 8192 / max_tokens <= 8192
 */
function maxTokensCap(e) {
  if (!(e instanceof UpstreamError) || e.status !== 400) return null;
  const s = String(e.snippet || '');
  if (!/max_(completion_)?tokens/.test(s)) return null;
  const m =
    s.match(/range of max_(?:completion_)?tokens is \[\s*\d+\s*,\s*(\d+)\s*\]/i) ||
    s.match(/max_(?:completion_)?tokens:\s*\d+\s*>\s*(\d+)/i) ||
    s.match(/less than or equal to\s*(\d+)/i) ||
    s.match(/<=\s*(\d+)/);
  const n = m ? Number(m[1]) : NaN;
  return Number.isInteger(n) && n > 0 ? n : null;
}

async function call(provider, payload, { stream, signal, timeoutMs }) {
  let res;
  try {
    res = await fetch(endpoint(provider), {
      method: 'POST',
      headers: headersFor(provider, stream),
      body: JSON.stringify(payload),
      signal: signalFor(signal, timeoutMs),
    });
  } catch (e) {
    if (e && (e.name === 'TimeoutError' || e.name === 'AbortError')) throw e;
    const code = (e && e.cause && e.cause.code) || (e && e.code) || '';
    throw new UpstreamError(0, `连接失败 ${code || (e && e.message) || ''}`.trim());
  }
  if (!res.ok) {
    let text = '';
    try {
      text = await res.text();
    } catch {
      /* 读不出正文就算了，状态码已经够定位 */
    }
    throw new UpstreamError(res.status, cut(text));
  }
  return res;
}

/** 等下一片数据，最多等 [ms]：超时抛 IdleTimeoutError，再叫 [onIdle] 掐断上游（顺序不能反：先掐断的话读到的是 AbortError）。 */
function withIdle(next, ms, onIdle) {
  let timer = null;
  // 超时之后 next 会因为连接被掐断而 reject：先挂一个空处理，免得变成未处理的 rejection 把进程带走。
  next.catch(() => {});
  return Promise.race([
    next,
    new Promise((_, reject) => {
      timer = setTimeout(() => {
        reject(new IdleTimeoutError(ms));
        if (onIdle) onIdle();
      }, ms);
    }),
  ]).finally(() => clearTimeout(timer));
}

/**
 * 字节流 → 一行一行（跨分片、跨多字节字符都安全）。给了 [idleMs] 时，两片之间隔太久就抛 IdleTimeoutError，
 * [onIdle] 负责掐断上游连接。
 */
async function* lines(res, idleMs = 0, onIdle = null) {
  const decoder = new TextDecoder('utf-8');
  let buf = '';
  const it = res.body[Symbol.asyncIterator]();
  for (;;) {
    const step = idleMs > 0 ? await withIdle(it.next(), idleMs, onIdle) : await it.next();
    if (step.done) break;
    buf += decoder.decode(step.value, { stream: true });
    let i;
    while ((i = buf.indexOf('\n')) >= 0) {
      const line = buf.slice(0, i);
      buf = buf.slice(i + 1);
      yield line.endsWith('\r') ? line.slice(0, -1) : line;
    }
  }
  buf += decoder.decode();
  if (buf) yield buf;
}

/** 一条 `data:` 的 payload；`[DONE]` 用 Symbol 表示，解析不了的返回 undefined。 */
const DONE = Symbol('done');
function payloadOf(line) {
  if (!line || line.startsWith(':')) return undefined;
  if (!line.startsWith('data:')) return undefined;
  const raw = line.slice(5).trim();
  if (!raw) return undefined;
  if (raw === '[DONE]') return DONE;
  try {
    return JSON.parse(raw);
  } catch {
    return undefined;
  }
}

/**
 * 流式对话。
 *
 * 发请求前的两条退让各自只有一次机会（非 2xx 在 call() 里就抛了，一个 delta 都还没发出去，重试不会吐重复文本）：
 *   1. 上游明说要 `max_completion_tokens` → 换字段重来；
 *   2. 上游 400 并给出 max_tokens 的合法上限（比这次要的小）→ 按上限重来一次。
 *
 * [timeoutMs] 是整条流的总时长上限（默认 120 秒）；[idleMs] > 0 时两片数据之间隔太久就抛 IdleTimeoutError 并掐断上游。
 * @param {{kind:string, baseUrl:string, model:string, apiKey?:string, extra?:object}} provider
 * @param {{system?:string, messages:{role:string,content:string|object[]}[], maxTokens?:number, signal?:AbortSignal,
 *          timeoutMs?:number, idleMs?:number}} opts
 * @param {(text:string)=>void} [onDelta]
 * @returns {Promise<{text:string, usage:{input:number, output:number}, stopReason:string}>}
 */
async function streamChat(provider, opts, onDelta) {
  const idleMs = Number(opts.idleMs) > 0 ? Number(opts.idleMs) : 0;
  // 空闲超时要能掐断上游：自己的一个 controller 叠在调用方的 signal 上。
  const idle = new AbortController();
  const signal = opts.signal ? AbortSignal.any([opts.signal, idle.signal]) : idle.signal;
  let payload = opts;
  let altMax = false;
  let triedAltMax = false;
  let triedCap = false;
  let res;
  for (;;) {
    try {
      res = await call(provider, bodyFor(provider, payload, true, altMax), { stream: true, signal, timeoutMs: opts.timeoutMs });
      break;
    } catch (e) {
      if (provider.kind === 'openai' && !triedAltMax && needsAltMaxTokens(e)) {
        triedAltMax = true;
        altMax = true;
        continue;
      }
      const cap = triedCap ? null : maxTokensCap(e);
      if (cap && cap < (payload.maxTokens || DEFAULT_MAX_TOKENS)) {
        triedCap = true;
        payload = { ...payload, maxTokens: cap };
        continue;
      }
      throw e;
    }
  }
  const usage = { input: 0, output: 0 };
  let text = '';
  let stopRaw = null;
  const push = (piece) => {
    if (typeof piece !== 'string' || piece === '') return;
    text += piece;
    if (onDelta) onDelta(piece);
  };
  const done = () => ({ text, usage, stopReason: stopReasonOf(provider.kind, stopRaw) });

  for await (const line of lines(res, idleMs, () => idle.abort())) {
    const ev = payloadOf(line);
    if (ev === undefined) continue;
    if (ev === DONE) break;

    // 两个协议都可能把错误塞进流里（HTTP 头已经 200 了）
    if (ev.type === 'error' || (ev.error && !ev.choices)) {
      const msg = (ev.error && (ev.error.message || ev.error.type)) || '未知错误';
      throw new UpstreamError(res.status || 502, cut(msg));
    }

    if (provider.kind === 'anthropic') {
      switch (ev.type) {
        case 'message_start':
          if (ev.message && ev.message.usage) {
            usage.input = Number(ev.message.usage.input_tokens) || 0;
            usage.output = Number(ev.message.usage.output_tokens) || usage.output;
          }
          break;
        case 'content_block_delta':
          if (ev.delta && typeof ev.delta.text === 'string') push(ev.delta.text);
          break;
        case 'message_delta':
          if (ev.delta && ev.delta.stop_reason) stopRaw = ev.delta.stop_reason;
          if (ev.usage) {
            if (ev.usage.output_tokens != null) usage.output = Number(ev.usage.output_tokens) || 0;
            if (ev.usage.input_tokens != null) usage.input = Number(ev.usage.input_tokens) || usage.input;
          }
          break;
        case 'message_stop':
          return done();
        default:
          break; // ping / content_block_start / content_block_stop / 未来新增
      }
    } else {
      const choice = Array.isArray(ev.choices) ? ev.choices[0] : null;
      if (choice && choice.delta && typeof choice.delta.content === 'string') push(choice.delta.content);
      if (choice && choice.finish_reason) stopRaw = choice.finish_reason;
      if (ev.usage) {
        usage.input = Number(ev.usage.prompt_tokens) || usage.input;
        usage.output = Number(ev.usage.completion_tokens) || usage.output;
      }
    }
  }
  return done();
}

function textOfCompletion(provider, data) {
  if (provider.kind === 'anthropic') {
    const blocks = Array.isArray(data && data.content) ? data.content : [];
    return blocks.filter((b) => b && b.type === 'text' && typeof b.text === 'string').map((b) => b.text).join('');
  }
  const msg = data && Array.isArray(data.choices) && data.choices[0] ? data.choices[0].message : null;
  return msg && typeof msg.content === 'string' ? msg.content : '';
}

function usageOfCompletion(provider, data) {
  const u = (data && data.usage) || {};
  return provider.kind === 'anthropic'
    ? { input: Number(u.input_tokens) || 0, output: Number(u.output_tokens) || 0 }
    : { input: Number(u.prompt_tokens) || 0, output: Number(u.completion_tokens) || 0 };
}

/**
 * 非流式。三条各自只有一次机会的退让，最多 4 次往返、不会打转：
 *   1. 上游明说要 `max_completion_tokens` → 换字段重来（**先试这条**，它是有明确
 *      信号的；先试它，gpt-5 上的 classify 就是 2 次往返而不是 3 次）；
 *   2. 上游 400 并给出 max_tokens 的合法上限（比这次要的小）→ 按上限重来；
 *   3. `json:true` 时上游不认 `response_format` → 去掉它重来（提示词本身已经
 *      要求只输出 JSON）。
 * @returns {Promise<{text:string, usage:{input:number, output:number}, stopReason:string}>}
 */
async function complete(provider, opts) {
  const isOpenai = provider.kind === 'openai';
  let json = !!opts.json && isOpenai;
  let payload = opts;
  let altMax = false;
  let triedAltMax = false;
  let triedCap = false;
  let triedDropJson = false;
  let res;
  for (;;) {
    try {
      res = await call(provider, bodyFor(provider, { ...payload, json }, false, altMax), { stream: false, signal: opts.signal });
      break;
    } catch (e) {
      if (isOpenai && !triedAltMax && needsAltMaxTokens(e)) {
        triedAltMax = true;
        altMax = true;
        continue;
      }
      const cap = triedCap ? null : maxTokensCap(e);
      if (cap && cap < (payload.maxTokens || DEFAULT_MAX_TOKENS)) {
        triedCap = true;
        payload = { ...payload, maxTokens: cap };
        continue;
      }
      if (json && !triedDropJson && e instanceof UpstreamError && e.status === 400) {
        triedDropJson = true;
        json = false;
        continue;
      }
      throw e;
    }
  }
  let data;
  try {
    data = await res.json();
  } catch {
    throw new UpstreamError(res.status, '上游返回的不是 JSON');
  }
  const raw = provider.kind === 'anthropic'
    ? data && data.stop_reason
    : data && Array.isArray(data.choices) && data.choices[0] ? data.choices[0].finish_reason : null;
  return { text: textOfCompletion(provider, data), usage: usageOfCompletion(provider, data), stopReason: stopReasonOf(provider.kind, raw) };
}

module.exports = {
  KINDS,
  PRESETS,
  STOP_REASONS,
  REQUEST_EXTRA_KEYS,
  UpstreamError,
  IdleTimeoutError,
  TIMEOUT_MS,
  DEFAULT_MAX_TOKENS,
  streamChat,
  complete,
  normalizeBaseUrl,
  isLocalHost,
  needsAltMaxTokens,
  maxTokensCap,
  visionOk,
};
