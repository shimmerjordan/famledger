'use strict';

// Client IP for rate-limiting and audit. Behind frp the remote address is the
// frps host; behind a Cloudflare Tunnel it is localhost — either way every
// caller would collapse into one bucket. With TRUST_PROXY=1 we prefer the
// forwarding headers (Cloudflare sets cf-connecting-ip, most proxies set
// x-forwarded-for). They are trivially spoofable when the server is exposed
// directly, which is exactly why the default is off.

function clientIp(req, trustProxy) {
  if (trustProxy) {
    const cf = req.headers['cf-connecting-ip'];
    if (cf) return String(cf).trim();
    const xff = req.headers['x-forwarded-for'];
    if (xff) return String(xff).split(',')[0].trim();
    const real = req.headers['x-real-ip'];
    if (real) return String(real).trim();
  }
  return req.socket?.remoteAddress || 'unknown';
}

module.exports = { clientIp };
