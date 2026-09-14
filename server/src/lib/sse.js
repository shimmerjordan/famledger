'use strict';

// Server-sent events, the one streaming shape this API needs (AI chat and the
// monthly report both stream `delta` → `done`). A 15 s comment heartbeat keeps
// idle proxies from closing the pipe; the timer is unref'd so it can never
// hold the process open.

function openSse(res, { heartbeatMs = 15000 } = {}) {
  res.writeHead(200, {
    'content-type': 'text/event-stream; charset=utf-8',
    'cache-control': 'no-cache, no-transform',
    connection: 'keep-alive',
    'x-accel-buffering': 'no',
  });
  res.write(': open\n\n');

  let closed = false;
  const beat = setInterval(() => {
    if (!closed) res.write(': ping\n\n');
  }, heartbeatMs);
  beat.unref?.();

  const stop = () => {
    if (closed) return;
    closed = true;
    clearInterval(beat);
  };
  res.on('close', stop);

  return {
    get closed() {
      return closed || res.writableEnded;
    },
    /** @param {string} event @param {unknown} obj JSON-serialisable payload */
    send(event, obj) {
      if (closed || res.writableEnded) return false;
      res.write(`event: ${event}\ndata: ${JSON.stringify(obj ?? null)}\n\n`);
      return true;
    },
    close() {
      stop();
      if (!res.writableEnded) res.end();
    },
  };
}

module.exports = { openSse };
