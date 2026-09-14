'use strict';

// 假上游：一个真的 Anthropic `/v1/messages`、一个真的 OpenAI `/v1/chat/completions`。
// 两个都说真 HTTP、真 SSE，并且**故意把 SSE 切碎**（40 字节一片，会切在行中间、
// 甚至切在一个 UTF-8 汉字的中间）——适配器的分片缓冲与解码只有这样才测得到。
//
//   const up = await startFakeAnthropic({ key: 'sk-x' });
//   up.base                       → http://127.0.0.1:<port>
//   up.state.status = 500         → 下一次请求回 500
//   up.state.parts / completion   → 流式分片 / 非流式文本
//   up.state.hang = true          → 发完第一片就挂住（测客户端断线 → 中止上游）
//   up.lastBody() / up.lastHeaders() / up.requests
//   up.text()                     → parts.join('')，断言拼接结果用

const http = require('node:http');

const DEFAULT_PARTS = ['本月支出 ', '偏高，', '建议先压一压餐饮支出。'];

function readBody(req) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    req.on('data', (c) => chunks.push(c));
    req.on('end', () => resolve(Buffer.concat(chunks).toString('utf8')));
    req.on('error', reject);
  });
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

/** 按字节切片写出去：行中间、甚至多字节字符中间都可能被切开。 */
async function writeChunked(res, text, { chunk = 40, delayMs = 1 } = {}) {
  const buf = Buffer.from(text, 'utf8');
  for (let i = 0; i < buf.length; i += chunk) {
    if (res.writableEnded || res.destroyed) return false;
    res.write(buf.subarray(i, i + chunk));
    await sleep(delayMs);
  }
  return true;
}

function sseHead(res) {
  res.writeHead(200, {
    'content-type': 'text/event-stream; charset=utf-8',
    'cache-control': 'no-cache',
    connection: 'keep-alive',
  });
}

function json(res, status, obj) {
  const body = Buffer.from(JSON.stringify(obj), 'utf8');
  res.writeHead(status, { 'content-type': 'application/json; charset=utf-8', 'content-length': body.length });
  res.end(body);
}

/** 共用的壳：起服务、记请求、记「客户端半路跑了」。 */
async function start(name, route, handle, opts) {
  const state = {
    status: 200,
    parts: opts.parts ? [...opts.parts] : [...DEFAULT_PARTS],
    completion: opts.completion ?? null,
    hang: false,
    streamError: false,
    rejectJsonMode: false,
    rejectMaxTokens: false,
    aborted: 0,
    inputTokens: 123,
    outputTokens: 45,
  };
  const requests = [];

  const server = http.createServer(async (req, res) => {
    const raw = await readBody(req);
    let body = null;
    try {
      body = raw ? JSON.parse(raw) : null;
    } catch {
      /* 让用例自己去看 raw */
    }
    const entry = { method: req.method, url: req.url, headers: { ...req.headers }, raw, body, finished: false };
    requests.push(entry);
    res.on('close', () => {
      if (!res.writableFinished) state.aborted++;
      else entry.finished = true;
    });

    if (req.url !== route || req.method !== 'POST') return json(res, 404, { error: { message: `no route ${req.method} ${req.url}` } });
    const authErr = opts.checkAuth(req);
    if (authErr) return json(res, 401, authErr);
    if (state.status !== 200) {
      return json(res, state.status, { error: { type: 'upstream_error', message: `fake ${name} is unhappy` } });
    }
    await handle(req, res, body || {}, state);
  });

  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
  const { port } = server.address();

  return {
    name,
    port,
    base: `http://127.0.0.1:${port}`,
    state,
    requests,
    text: () => state.parts.join(''),
    lastBody: () => (requests.length ? requests[requests.length - 1].body : null),
    lastHeaders: () => (requests.length ? requests[requests.length - 1].headers : null),
    stop: () =>
      new Promise((resolve) => {
        server.closeAllConnections?.();
        server.close(() => resolve());
      }),
  };
}

/** Anthropic Messages API。`x-api-key` + `anthropic-version` 都要对。 */
async function startFakeAnthropic(opts = {}) {
  const key = opts.key === null ? null : opts.key || 'sk-ant-fake';
  return start(
    'anthropic',
    '/v1/messages',
    async (req, res, body, state) => {
      const text = state.completion ?? state.parts.join('');
      if (!body.stream) {
        return json(res, 200, {
          id: 'msg_fake',
          type: 'message',
          role: 'assistant',
          content: [{ type: 'text', text }],
          usage: { input_tokens: state.inputTokens, output_tokens: state.outputTokens },
        });
      }
      sseHead(res);
      const frame = (event, data) => `event: ${event}\ndata: ${JSON.stringify(data)}\n\n`;
      await writeChunked(
        res,
        frame('message_start', {
          type: 'message_start',
          message: { id: 'msg_fake', role: 'assistant', usage: { input_tokens: state.inputTokens, output_tokens: 0 } },
        }) + frame('content_block_start', { type: 'content_block_start', index: 0, content_block: { type: 'text', text: '' } }),
      );
      for (const part of state.parts) {
        await writeChunked(res, frame('content_block_delta', { type: 'content_block_delta', index: 0, delta: { type: 'text_delta', text: part } }));
        if (state.streamError) {
          // 头已经 200 了，错误只能从流里出去 —— Anthropic 过载时就是这样
          await writeChunked(res, frame('error', { type: 'error', error: { type: 'overloaded_error', message: '服务繁忙，稍后再试' } }));
          return res.end();
        }
        if (state.hang) {
          // 永远不结束：等客户端自己断
          for (let i = 0; i < 600 && !res.writableEnded && !res.destroyed; i++) await sleep(10);
          return;
        }
      }
      await writeChunked(
        res,
        frame('content_block_stop', { type: 'content_block_stop', index: 0 }) +
          frame('message_delta', { type: 'message_delta', delta: { stop_reason: 'end_turn' }, usage: { output_tokens: state.outputTokens } }) +
          frame('message_stop', { type: 'message_stop' }),
      );
      res.end();
    },
    {
      ...opts,
      checkAuth(req) {
        if (key && req.headers['x-api-key'] !== key) return { error: { message: 'bad x-api-key' } };
        if (req.headers['anthropic-version'] !== '2023-06-01') return { error: { message: 'missing anthropic-version' } };
        return null;
      },
    },
  );
}

/** OpenAI Chat Completions。`Authorization: Bearer …` 要对。 */
async function startFakeOpenai(opts = {}) {
  const key = opts.key === null ? null : opts.key || 'sk-oai-fake';
  return start(
    'openai',
    '/v1/chat/completions',
    async (req, res, body, state) => {
      const text = state.completion ?? state.parts.join('');
      if (state.rejectMaxTokens && body.max_tokens !== undefined) {
        // gpt-5 / o 系列的原话
        return json(res, 400, {
          error: {
            type: 'invalid_request_error',
            param: 'max_tokens',
            message: "Unsupported parameter: 'max_tokens' is not supported with this model. Use 'max_completion_tokens' instead.",
          },
        });
      }
      if (body.response_format && state.rejectJsonMode) {
        return json(res, 400, { error: { message: 'response_format is not supported by this model' } });
      }
      if (!body.stream) {
        return json(res, 200, {
          id: 'chatcmpl-fake',
          choices: [{ index: 0, message: { role: 'assistant', content: text }, finish_reason: 'stop' }],
          usage: { prompt_tokens: state.inputTokens, completion_tokens: state.outputTokens },
        });
      }
      sseHead(res);
      const frame = (data) => `data: ${JSON.stringify(data)}\n\n`;
      for (const part of state.parts) {
        await writeChunked(res, frame({ id: 'chatcmpl-fake', object: 'chat.completion.chunk', choices: [{ index: 0, delta: { content: part } }] }));
        if (state.hang) {
          for (let i = 0; i < 600 && !res.writableEnded && !res.destroyed; i++) await sleep(10);
          return;
        }
      }
      await writeChunked(
        res,
        frame({ id: 'chatcmpl-fake', choices: [{ index: 0, delta: {}, finish_reason: 'stop' }] }) +
          frame({ id: 'chatcmpl-fake', choices: [], usage: { prompt_tokens: state.inputTokens, completion_tokens: state.outputTokens } }) +
          'data: [DONE]\n\n',
      );
      res.end();
    },
    {
      ...opts,
      checkAuth(req) {
        if (key && req.headers.authorization !== `Bearer ${key}`) return { error: { message: 'bad Authorization' } };
        return null;
      },
    },
  );
}

module.exports = { startFakeAnthropic, startFakeOpenai, DEFAULT_PARTS };
