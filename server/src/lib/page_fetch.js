'use strict';

// 网址导入的抓取和防护（spec §4 `POST /asset-import/fetch`、§6「网址」、§8 SSRF 矩阵）。服务端替用户去拿一个网页，
// 所以它不能被拿来探内网：
//
//   · 只收 http / https；网址里不能带用户名密码；没写协议的按 https；
//   · 先解析 DNS，**每一个**解析结果都要是公网地址：回环、私网（含 100.64/10 运营商 NAT、IPv6 的 fc00::/7）、链路本地、
//     IPv4 映射 / 兼容的 IPv6、组播、保留段、fake-ip 段 198.18.0.0/15 一律拦下（allowFakeIp 时放开 fake-ip 段）；
//     连接时钉死在检查过的这几个地址上（自己的 lookup），不会检查一次、连的时候又解析出别的地址（DNS 重绑定）；
//   · allowFakeIp 时 DNS 回的是代理的假地址，真实目标由代理自己再解析、服务端看不到 —— 这时只抓「像公网网站」的网址：
//     不收 IP 直写、单段主机名（db、router）和 .local / .lan / .home / .internal / .localdomain / .arpa 这类内网后缀
//     （挡住最直接的「借代理探内网」；解析到内网的真域名仍然挡不住，所以接口那边放开后只给管理员用）；
//   · 重定向手动跟、最多 3 跳，每一跳都重新检查协议和地址；
//   · 正文（解压之后）超过 2MB 立刻中止；从解析 DNS 到读完正文总共 10 秒；
//   · 编码按 Content-Type 的 charset → <meta charset> → BOM → UTF-8 认，GBK / GB2312 按 GB18030 解；
//   · 提取正文：去掉脚本、样式、导航、页脚这些，有 <article> / <main> 且够长就只取它；
//   · PDF、登录墙、正文太短不算失败，回一句能看懂的降级提示（hint + message），App 给「改用截图 / 改用粘贴」。
//
// 读完正文之后的处理（解码、去标签、找 <meta>、判登录墙）是同步的，10 秒总超时管不到，Node 又是单线程 —— 这一段卡住就是
// 整个服务端卡住。所以对最多 2MB 的网页一律**线性**处理：去标签、找标签都是 indexOf 一趟扫过去；正则只跑在长度有上限的
// 小片段（一个标签、一行）上，而且不写嵌套或前后重叠的量词。像 /<input\b[^>]*type=password/ 这种对整页跑的正则，页面里
// 一大堆 `<input ` 却没有 `>` 时每个起点都要吃到文末再一格一格退回来，是 O(n²)：2MB 能卡上几分钟（测试里有这种页面）。
//
//   parseTarget(raw, field) → URL                      只看写法（协议、用户名密码、长度），不解析 DNS；坏了 400 invalid_<field>
//   blockedReason(address, {allowFakeIp}) → null | 'loopback' | 'private' | 'link_local' | 'mapped' | 'fake_ip' | 'multicast' | 'reserved'
//   fetchPage(raw, opts) → {url, finalUrl, title, text, chars, truncated, hint, message}
//       opts.lookup(host) → Promise<[{address, family}]>   默认 dns.promises.lookup(host, {all:true, hints:ADDRCONFIG})；测试注入假的
//       opts.allowFakeIp  放开 198.18.0.0/15（服务端网络用了 Clash 这类 fake-ip 代理时），同时收紧主机名（见上）
//       opts.timeoutMs / maxBytes / maxRedirects         默认 10 秒 / 2MB / 3 跳
//       opts.dial(address) → address                     测试用：检查通过之后实际连哪个地址（本地测试服务器）；生产不传
//   htmlToText(html) → {title, text}
//   looksLikeLogin(status, finalUrl, html, text) → bool
//
// 失败一律抛 HttpError：400 invalid_url / url_blocked（details.fakeIp）、502 dns_failed / too_many_redirects / page_too_large /
// unsupported_page / fetch_failed、504 fetch_timeout。被拦时说明里不带解析出的地址（不给成员借服务端的 DNS 查内网主机的 IP）；
// 地址挂在错误的 blockedAddress 上（不进回应），调用方只写 debug 日志。

const dns = require('node:dns');
const http = require('node:http');
const https = require('node:https');
const net = require('node:net');
const zlib = require('node:zlib');
const { PassThrough } = require('node:stream');

const { HttpError } = require('./router');

const TIMEOUT_MS = 10000;
const MAX_BYTES = 2 * 1024 * 1024;
const MAX_REDIRECTS = 3;
const MAX_URL = 2000;
/** 抽出来的正文最多这么多字（和 extract 的粘贴上限一样）。 */
const MAX_TEXT = 20000;
/** 正文少于这么多字算「太短」（多半是靠脚本渲染的页面）。 */
const SHORT_TEXT = 60;
const USER_AGENT = 'Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0 Mobile Safari/537.36 famledger/0.2';

const HINT_MESSAGE = {
  pdf: '这是一个 PDF 文件，网页抓取读不了里面的字。截个图，或者把文字复制出来粘贴。',
  login: '这个页面要登录才能看到内容，抓到的多半只是登录页。登录后截图，或者把权益说明复制出来粘贴。',
  short: '只抓到很少的字（这类页面常靠脚本加载内容）。截图或者复制粘贴会更准。',
};

const bad = (field, message) => new HttpError(400, `invalid_${field}`, message);

/** 网址的写法：http / https、不带用户名密码、≤2000 字；没写协议的按 https。返回去掉 #锚点 的 URL。 */
function parseTarget(raw, field = 'url') {
  if (typeof raw !== 'string' || !raw.trim()) throw bad(field, '先填一个网址');
  let s = raw.trim();
  if (s.length > MAX_URL) throw bad(field, `网址最长 ${MAX_URL} 个字`);
  if (!/^[a-z][a-z0-9+.-]*:\/\//i.test(s)) s = `https://${s}`;
  let u;
  try {
    u = new URL(s);
  } catch {
    throw bad(field, '这不是一个有效的网址');
  }
  if (u.protocol !== 'http:' && u.protocol !== 'https:') throw bad(field, '只能抓 http 或 https 开头的网址');
  if (u.username || u.password) throw bad(field, '网址里不能带用户名和密码');
  u.hash = '';
  return u;
}

// —— 地址分类 ——

/** '1.2.3.4' → [1,2,3,4]；不是点分十进制的 IPv4 回 null。 */
function v4Bytes(s) {
  if (net.isIPv4(s) !== true) return null;
  return s.split('.').map(Number);
}

/** IPv6 文本（可带 %zone、结尾可以是点分 IPv4）→ 16 字节；不是 IPv6 回 null。 */
function v6Bytes(raw) {
  const s = String(raw).split('%')[0];
  if (!net.isIPv6(s)) return null;
  let head = s;
  const tail = [];
  const lastColon = s.lastIndexOf(':');
  if (s.includes('.', lastColon)) {
    const v4 = v4Bytes(s.slice(lastColon + 1));
    if (!v4) return null;
    tail.push((v4[0] << 8) | v4[1], (v4[2] << 8) | v4[3]);
    head = s.slice(0, lastColon + 1);
    if (!head.endsWith('::')) head = head.slice(0, -1);
  }
  const [left, right] = head.includes('::') ? head.split('::') : [head, null];
  const parse = (part) => (part ? part.split(':').filter((x) => x !== '').map((h) => parseInt(h, 16)) : []);
  const l = parse(left);
  const r = right === null ? [] : parse(right);
  const fill = 8 - tail.length - l.length - r.length;
  if (right === null && fill !== 0) return null;
  const words = [...l, ...Array(Math.max(0, fill)).fill(0), ...r, ...tail];
  if (words.length !== 8) return null;
  const out = [];
  for (const w of words) out.push((w >> 8) & 0xff, w & 0xff);
  return out;
}

/** IPv4 的 [网络, 前缀长度, 原因]。198.18.0.0/15 单独处理（可放开）。 */
const V4_BLOCKS = [
  [[0, 0, 0, 0], 8, 'reserved'],
  [[10, 0, 0, 0], 8, 'private'],
  [[100, 64, 0, 0], 10, 'private'],
  [[127, 0, 0, 0], 8, 'loopback'],
  [[169, 254, 0, 0], 16, 'link_local'],
  [[172, 16, 0, 0], 12, 'private'],
  [[192, 0, 0, 0], 24, 'reserved'],
  [[192, 168, 0, 0], 16, 'private'],
  [[224, 0, 0, 0], 4, 'multicast'],
  [[240, 0, 0, 0], 4, 'reserved'],
];

function inPrefix(bytes, net4, bits) {
  for (let i = 0; i < bytes.length && bits > 0; i++, bits -= 8) {
    const mask = bits >= 8 ? 0xff : (0xff << (8 - bits)) & 0xff;
    if ((bytes[i] & mask) !== (net4[i] & mask)) return false;
  }
  return true;
}

function v4Reason(b, allowFakeIp) {
  for (const [n, bits, why] of V4_BLOCKS) if (inPrefix(b, n, bits)) return why;
  if (!allowFakeIp && inPrefix(b, [198, 18, 0, 0], 15)) return 'fake_ip';
  return null;
}

/**
 * 这个地址能不能连：能回 null，不能回原因。认不出的写法（既不是 IPv4 也不是 IPv6）当保留地址拦下。
 * @param {string} address
 * @param {{allowFakeIp?: boolean}} [opts]
 */
function blockedReason(address, { allowFakeIp = false } = {}) {
  const s = String(address).replace(/^\[|\]$/g, '');
  const b4 = v4Bytes(s);
  if (b4) return v4Reason(b4, allowFakeIp);
  const b = v6Bytes(s);
  if (!b) return 'reserved';
  const zeros = (from, to) => b.slice(from, to).every((x) => x === 0);
  if (zeros(0, 15) && b[15] === 1) return 'loopback'; // ::1
  if (zeros(0, 16)) return 'reserved'; // ::
  if (zeros(0, 10) && b[10] === 0xff && b[11] === 0xff) return 'mapped'; // ::ffff:0:0/96
  if (zeros(0, 12)) return 'mapped'; // ::a.b.c.d（IPv4 兼容，早就废弃了）
  // NAT64（64:ff9b::/96）和 6to4（2002::/16）里嵌着 IPv4：按嵌着的那个判。
  if (b[0] === 0x00 && b[1] === 0x64 && b[2] === 0xff && b[3] === 0x9b && zeros(4, 12)) return v4Reason(b.slice(12), allowFakeIp);
  if (b[0] === 0x00 && b[1] === 0x64 && b[2] === 0xff && b[3] === 0x9b) return 'private'; // 64:ff9b:1::/48 本地用
  if (b[0] === 0x20 && b[1] === 0x02) return v4Reason(b.slice(2, 6), allowFakeIp);
  if ((b[0] & 0xfe) === 0xfc) return 'private'; // fc00::/7
  if (b[0] === 0xfe && (b[1] & 0xc0) === 0x80) return 'link_local'; // fe80::/10
  if (b[0] === 0xfe && (b[1] & 0xc0) === 0xc0) return 'reserved'; // fec0::/10
  if (b[0] === 0xff) return 'multicast';
  if (b[0] === 0x01 && b[1] === 0x00 && zeros(2, 8)) return 'reserved'; // 100::/64 丢弃
  return null;
}

/** 放开 fake-ip 的代价，拦截说明、README、compose 注释说的是同一句。 */
const FAKE_IP_COST = '放开后服务端没法核实网址的真实目标地址，只在信得过全家成员时打开，而且放开后只有管理员能用网址导入';

/** 被拦：说明里不带解析出的地址（地址挂在 blockedAddress 上，只给调用方写 debug 日志，不进回应）。 */
function blockedError(address, why) {
  const e = why === 'fake_ip'
    ? new HttpError(400, 'url_blocked',
      '这个网址解析到了 fake-ip 代理用的 198.18.0.0/15 段，默认不抓。服务端的网络走 Clash 这类 fake-ip 代理的话，管理员可以在 ' +
      `compose 的 .env 里加 URL_FETCH_ALLOW_FAKEIP=1，再 docker compose up -d 重启服务才生效；${FAKE_IP_COST}。`, { fakeIp: true })
    : new HttpError(400, 'url_blocked', '这个网址指向本机或内网地址，不能抓取', { fakeIp: false });
  e.blockedAddress = address;
  return e;
}

/** 放开 fake-ip 时不收的主机名后缀（内网、保留的顶级域）：代理会把它们交给内网 DNS 或直连。 */
const INTERNAL_SUFFIXES = new Set(['local', 'localhost', 'localdomain', 'lan', 'home', 'internal', 'intranet', 'corp', 'private', 'arpa']);

/**
 * 放开 fake-ip 时的主机名检查：DNS 回的是假地址、查不出真实目标，只收「像公网网站」的：带点的域名，不是 IP 直写、
 * 不是单段主机名（db、router、nas），也不以内网后缀结尾。能抓回 null，不能抓回说明。
 */
function fakeIpHostProblem(host) {
  const h = host.toLowerCase().replace(/\.$/, '');
  if (net.isIP(h)) return '已放开 fake-ip 抓取，这时服务端核实不了真实地址，不抓直接写 IP 的网址，换成带域名的';
  const labels = h.split('.');
  if (labels.length < 2 || labels.some((l) => l === '')) return '已放开 fake-ip 抓取，这时只抓带域名的公网网址，不抓 db、nas 这类内网主机名';
  if (INTERNAL_SUFFIXES.has(labels[labels.length - 1])) return '已放开 fake-ip 抓取，这时不抓 .local、.lan 这类内网地址';
  return null;
}

// hints: ADDRCONFIG —— 本机没有 IPv6 路由就别拿 AAAA 记录（Node 自己连接时也带这个）。
const defaultLookup = (host) => dns.promises.lookup(host, { all: true, verbatim: true, hints: dns.ADDRCONFIG });

// —— 一跳 ——

/**
 * 解析并检查一个网址的主机：返回 {host, addresses:[{address, family}]}（全部检查过，连接时按顺序试）；任何一个解析结果
 * 不能连都拦下。放开 fake-ip 时先看主机名（见 fakeIpHostProblem），不对就连 DNS 都不问。
 */
async function resolveSafe(u, { lookup, allowFakeIp, race }) {
  const host = u.hostname.replace(/^\[|\]$/g, '');
  if (allowFakeIp) {
    const problem = fakeIpHostProblem(host);
    if (problem) throw new HttpError(400, 'url_blocked', problem, { fakeIp: false });
  }
  let list;
  if (net.isIP(host)) list = [{ address: host, family: net.isIP(host) }];
  else {
    try {
      list = await race(lookup(host));
    } catch (e) {
      if (e instanceof HttpError) throw e;
      throw new HttpError(502, 'dns_failed', `找不到这个网站（${host}），检查一下网址`);
    }
  }
  if (!Array.isArray(list) || !list.length) throw new HttpError(502, 'dns_failed', `找不到这个网站（${host}），检查一下网址`);
  for (const a of list) {
    const why = blockedReason(a.address, { allowFakeIp });
    if (why) throw blockedError(a.address, why);
  }
  return { host, addresses: list.map((a) => ({ address: a.address, family: a.family || net.isIP(a.address) })) };
}

/**
 * OpenSSL 校验证书时的错误码（Node 原样放在 e.code 上）。名字里带 CERT 的另外一并算；这几个不带：证书链不完整
 * （服务器漏发中间证书，浏览器会自己补、Node 不会，很常见）、CA 不对、链太长、用途不对、主机名不符。
 */
const CERT_CODES = new Set([
  'UNABLE_TO_VERIFY_LEAF_SIGNATURE', 'UNABLE_TO_DECRYPT_CERT_SIGNATURE', 'UNABLE_TO_DECODE_ISSUER_PUBLIC_KEY', 'INVALID_CA',
  'PATH_LENGTH_EXCEEDED', 'INVALID_PURPOSE', 'HOSTNAME_MISMATCH',
]);

/** 连接出错 → 给人看的原因（不回显 Node 的英文原话里的建议，比如「try running Node.js with --use-system-ca」）。 */
function connectError(e, u) {
  const code = e && e.code;
  if (code === 'ECONNREFUSED') return new HttpError(502, 'fetch_failed', `连不上 ${u.host}（拒绝连接）`);
  if (code === 'ECONNRESET' || code === 'EPIPE') return new HttpError(502, 'fetch_failed', `${u.host} 把连接断开了`);
  if (typeof code === 'string' && (code.startsWith('ERR_TLS') || code.includes('CERT') || CERT_CODES.has(code))) {
    return new HttpError(502, 'fetch_failed', `${u.host} 的证书有问题（过期、不受信任或者证书链不完整），服务端打不开。改用截图或复制粘贴吧`);
  }
  return new HttpError(502, 'fetch_failed', `打不开 ${u.host}：${(e && e.message) || '未知错误'}`.slice(0, 200));
}

const REDIRECTS = [301, 302, 303, 307, 308];

/** Content-Type → 怎么读：html | text | pdf | binary（octet-stream：看开头是不是 PDF）| other（图片、压缩包……不读）。没写按 html。 */
function kindOf(contentType) {
  const t = String(contentType || '').toLowerCase().split(';')[0].trim();
  if (!t) return 'html';
  if (t === 'application/pdf') return 'pdf';
  if (t.includes('html') || t.includes('xml')) return 'html';
  if (t.startsWith('text/') || t.includes('json')) return 'text';
  if (t === 'application/octet-stream' || t === 'binary/octet-stream') return 'binary';
  return 'other';
}

/**
 * 发一次 GET。返回 {status, headers, kind, body:Buffer, redirect?, pdf?, unsupported?}：重定向、出错的状态码、不是网页的
 * 不读正文；PDF 一看出来就不往下读；正文（解压后）超过 [maxBytes] 立刻中止、抛 page_too_large。
 */
function requestOnce(u, target, { signal, maxBytes }) {
  return new Promise((resolve, reject) => {
    const mod = u.protocol === 'https:' ? https : http;
    // 钉死在检查过的地址上：Node 自己解析时会问这个 lookup。autoSelectFamily 开着时带 all:true，给全部检查过的地址
    // （第一个连不上 Node 会接着试下一个）；不带 all 时给第一个。
    const [first] = target.addresses;
    const pinned = (hostname, opts, cb) => {
      if (opts && opts.all) cb(null, target.addresses.map((a) => ({ address: a.address, family: a.family })));
      else cb(null, first.address, first.family);
    };
    let settled = false;
    const done = (fn, value) => {
      if (settled) return;
      settled = true;
      fn(value);
    };
    const empty = Buffer.alloc(0);
    const req = mod.request({
      method: 'GET',
      hostname: target.host,
      port: u.port || (u.protocol === 'https:' ? 443 : 80),
      path: `${u.pathname}${u.search}`,
      headers: {
        'user-agent': USER_AGENT,
        accept: 'text/html,application/xhtml+xml,text/plain;q=0.9,*/*;q=0.5',
        'accept-language': 'zh-CN,zh;q=0.9,en;q=0.5',
        'accept-encoding': 'gzip, deflate, br',
      },
      lookup: pinned,
      agent: false,
      signal,
    }, (res) => {
      const status = res.statusCode || 0;
      const headers = res.headers;
      const kind = kindOf(headers['content-type']);
      const stop = (value) => {
        req.destroy();
        done(resolve, { status, headers, kind, body: empty, ...value });
      };
      if (REDIRECTS.includes(status)) return stop({ redirect: headers.location || null });
      if (status >= 400 && status !== 401 && status !== 403) return stop({});
      if (kind === 'pdf') return stop({ pdf: true });
      if (kind === 'other') return stop({ unsupported: true });
      const enc = String(headers['content-encoding'] || '').toLowerCase().trim();
      const declared = Number(headers['content-length']);
      if ((!enc || enc === 'identity') && Number.isFinite(declared) && declared > maxBytes) {
        req.destroy();
        return done(reject, tooLarge(maxBytes));
      }
      let stream = res;
      if (enc === 'gzip' || enc === 'x-gzip') stream = res.pipe(zlib.createGunzip());
      else if (enc === 'deflate') stream = inflateAny(res);
      else if (enc === 'br') stream = res.pipe(zlib.createBrotliDecompress());
      const chunks = [];
      let size = 0;
      stream.on('data', (c) => {
        if (settled) return;
        if (size === 0) {
          if (c.subarray(0, 5).toString('latin1') === '%PDF-') return stop({ pdf: true });
          if (kind === 'binary') return stop({ unsupported: true });
        }
        size += c.length;
        if (size > maxBytes) {
          req.destroy();
          if (stream !== res) stream.destroy();
          return done(reject, tooLarge(maxBytes));
        }
        chunks.push(c);
      });
      stream.on('end', () => done(resolve, { status, headers, kind, body: Buffer.concat(chunks) }));
      stream.on('error', (e) => done(reject, e));
      res.on('error', (e) => done(reject, e));
      res.on('close', () => {
        if (!res.complete) done(reject, Object.assign(new Error('connection closed before the body ended'), { code: 'ECONNRESET' }));
      });
    });
    req.on('error', (e) => done(reject, e));
    req.end();
  });
}

/**
 * Content-Encoding: deflate 按规范是带 zlib 头的，但不少站点发的是裸 deflate（浏览器两种都认）：看头两个字节再选
 * createInflate 还是 createInflateRaw。返回的流被 destroy 时连带销毁解压器。
 */
function inflateAny(res) {
  const out = new PassThrough();
  let inflater = null;
  const head = [];
  let headLen = 0;
  const pick = () => {
    const h = Buffer.concat(head);
    const wrapped = h.length >= 2 && (h[0] & 0x0f) === 8 && (h[0] * 256 + h[1]) % 31 === 0;
    inflater = wrapped ? zlib.createInflate() : zlib.createInflateRaw();
    inflater.on('error', (e) => out.destroy(e));
    inflater.pipe(out);
    inflater.write(h);
  };
  res.on('data', (c) => {
    if (inflater) return void inflater.write(c);
    head.push(c);
    headLen += c.length;
    if (headLen >= 2) pick();
  });
  res.on('end', () => {
    if (!inflater) pick();
    inflater.end();
  });
  out.on('close', () => {
    if (inflater) inflater.destroy();
  });
  return out;
}

const tooLarge = (maxBytes) => new HttpError(502, 'page_too_large', `网页超过 ${Math.round(maxBytes / 1024 / 1024)}MB，没抓完。改用截图或复制粘贴吧`);

// —— 编码和正文 ——

/** 「charset=gbk」「charset = "utf-8"」：只跑在一个响应头、一个标签上；`=` 后面的空白和引号用一个字符类吃掉（不写 \s*["']?\s* 这种前后重叠的）。 */
const CHARSET_RE = /charset\s*=[\s"']*([\w.:-]+)/i;

/** 声明的编码：Content-Type 的 charset，没有就看正文开头 4KB 里 <meta charset> / http-equiv 那个标签。 */
function charsetOf(contentType, body) {
  const m = CHARSET_RE.exec(String(contentType || '').slice(0, 1024));
  if (m) return m[1];
  const head = body.subarray(0, 4096).toString('latin1');
  for (const [s, e] of tagsOf(head.toLowerCase(), 'meta')) {
    const meta = CHARSET_RE.exec(head.slice(s, e));
    if (meta) return meta[1];
  }
  return null;
}

/** 按声明的编码解；有 BOM 听 BOM 的；GBK、GB2312 按 GB18030（它们的超集）；认不出的编码按 UTF-8。 */
function decodeBody(body, label) {
  if (body[0] === 0xef && body[1] === 0xbb && body[2] === 0xbf) return new TextDecoder('utf-8').decode(body.subarray(3));
  if (body[0] === 0xff && body[1] === 0xfe) return new TextDecoder('utf-16le').decode(body.subarray(2));
  if (body[0] === 0xfe && body[1] === 0xff) return new TextDecoder('utf-16be').decode(body.subarray(2));
  let enc = String(label || 'utf-8').toLowerCase();
  if (['gbk', 'gb2312', 'x-gbk', 'gb_2312-80', 'cp936'].includes(enc)) enc = 'gb18030';
  try {
    return new TextDecoder(enc).decode(body);
  } catch {
    return new TextDecoder('utf-8').decode(body);
  }
}

const ENTITIES = {
  nbsp: ' ', amp: '&', lt: '<', gt: '>', quot: '"', apos: "'", yen: '¥', middot: '·', mdash: '—', ndash: '–', hellip: '…',
  ldquo: '“', rdquo: '”', lsquo: '‘', rsquo: '’', times: '×', copy: '©', reg: '®', ensp: ' ', emsp: ' ', rarr: '→', laquo: '«', raquo: '»',
};

function decodeEntities(s) {
  return s.replace(/&(#x[0-9a-f]+|#\d+|[a-z]+);/gi, (all, e) => {
    if (e[0] === '#') {
      const cp = e[1] === 'x' || e[1] === 'X' ? parseInt(e.slice(2), 16) : parseInt(e.slice(1), 10);
      return Number.isInteger(cp) && cp > 0 && cp <= 0x10ffff ? String.fromCodePoint(cp) : all;
    }
    return ENTITIES[e.toLowerCase()] ?? all;
  });
}

/** 整段跳过的元素（连同里面的内容）。 */
const SKIP = new Set(['script', 'style', 'noscript', 'template', 'svg', 'iframe', 'head', 'canvas', 'object', 'select', 'nav', 'footer', 'aside']);
/** 换行的元素。 */
const BLOCK = new Set(['p', 'div', 'br', 'tr', 'li', 'ul', 'ol', 'dl', 'dt', 'dd', 'h1', 'h2', 'h3', 'h4', 'h5', 'h6', 'section', 'article',
  'main', 'header', 'table', 'blockquote', 'pre', 'form', 'hr', 'figure', 'figcaption', 'address']);

/**
 * 去标签：一趟线性扫描（不用回溯的正则，坏页面、没闭合的标签也不会卡住）。块级元素换行，表格单元格之间空格，
 * 跳过 SKIP 里的元素，解实体，逐行去掉多余空白、丢掉空行。
 */
function stripTags(html) {
  const lower = html.toLowerCase();
  let out = '';
  let i = 0;
  while (i < html.length) {
    const lt = html.indexOf('<', i);
    if (lt < 0) {
      out += html.slice(i);
      break;
    }
    out += html.slice(i, lt);
    const next = html[lt + 1] || '';
    if (lower.startsWith('<!--', lt)) {
      const end = html.indexOf('-->', lt + 4);
      i = end < 0 ? html.length : end + 3;
      continue;
    }
    if (!/[a-z/!?]/i.test(next)) {
      out += '<';
      i = lt + 1;
      continue;
    }
    const gt = html.indexOf('>', lt + 1);
    if (gt < 0) break;
    i = gt + 1;
    const m = /^<(\/?)\s*([a-z][a-z0-9-]*)/.exec(lower.slice(lt, Math.min(gt + 1, lt + 64)));
    if (!m) continue;
    const [, closing, name] = m;
    if (!closing && SKIP.has(name) && html[gt - 1] !== '/') {
      const end = lower.indexOf(`</${name}`, i);
      if (end < 0) {
        i = html.length;
      } else {
        const close = html.indexOf('>', end);
        i = close < 0 ? html.length : close + 1;
      }
      out += '\n';
      continue;
    }
    if (name === 'td' || name === 'th') out += ' ';
    else if (BLOCK.has(name)) out += name === 'li' && !closing ? '\n· ' : '\n';
  }
  return decodeEntities(out)
    .split('\n')
    .map((line) => line.replace(/[\s 　]+/g, ' ').trim())
    .filter((line) => line !== '' && line !== '·')
    .join('\n');
}

/** 一个标签最长这么多字；更长的（多半是坏页面、或者故意塞的）不看。 */
const MAX_TAG = 2048;

/**
 * 按顺序给出 [lower] 里每个 `<name …>` 标签的 [起, 止)（止在 `>` 之后），给调用方切出来再跑小正则。一趟线性扫描：
 *   · indexOf 找 `<name`，名字后面得是空白、`/` 或 `>`（`<meta` 不算 `<metadata`）；
 *   · 找到的 `>` 记下来复用：同一个 `>` 前面挤着再多 `<name` 也只往后找一次；
 *   · 一个 `>` 只配一个标签（前面几个 `<name` 共用同一个 `>` 时，给第一个不超长的那个 —— 它包含了后面那些的全部属性），
 *     所以给出的片段互不重叠，总长不超过全文，调用方在片段上跑的正则合起来也是线性的；
 *   · 后面再也没有 `>` 就停；超过 MAX_TAG 的不给。
 * 这里不用 /<meta\b[^>]*>/g 这种正则：一大堆 `<meta` 却没有 `>` 时每个起点都要吃到文末再退回来，是 O(n²)。
 */
function* tagsOf(lower, name) {
  const open = `<${name}`;
  let gt = -1;
  let used = -1;
  for (let p = lower.indexOf(open); p >= 0; p = lower.indexOf(open, p + open.length)) {
    const next = lower[p + open.length];
    if (next !== undefined && next !== '>' && next !== '/' && !/\s/.test(next)) continue;
    if (gt < p) gt = lower.indexOf('>', p);
    if (gt < 0) return;
    if (gt === used || gt - p > MAX_TAG) continue;
    used = gt;
    yield [p, gt + 1];
  }
}

/** meta 标签里说它是描述：name / property = description、og:description。只跑在一个标签（≤ MAX_TAG）上。 */
const DESCRIPTION_RE = /(?:name|property)\s*=[\s"']*(?:og:)?description["'\s/>]/;
/** 标签里 content 的值：引号里面的（[^"]* 碰到下一个引号就停，不回溯）。 */
const CONTENT_RE = /content\s*=\s*(?:"([^"]*)"|'([^']*)')/i;

/** <title> 和 <meta name="description"> / og:description（只在开头 64KB 里找）。 */
function headOf(html) {
  const head = html.slice(0, 65536);
  const lower = head.toLowerCase();
  let title = '';
  const t = lower.indexOf('<title');
  if (t >= 0) {
    const s = lower.indexOf('>', t);
    const e = s < 0 ? -1 : lower.indexOf('</title', s);
    if (s >= 0 && e > s) title = decodeEntities(head.slice(s + 1, Math.min(e, s + 1 + 2000))).replace(/\s+/g, ' ').trim();
  }
  let description = '';
  for (const [s, e] of tagsOf(lower, 'meta')) {
    if (!DESCRIPTION_RE.test(lower.slice(s, e))) continue;
    const c = CONTENT_RE.exec(head.slice(s, e));
    if (c) {
      description = decodeEntities(c[1] ?? c[2] ?? '').replace(/\s+/g, ' ').trim();
      break;
    }
  }
  return { title: title.slice(0, 200), description: description.slice(0, 500) };
}

/**
 * HTML → {title, text}。有 <article> / <main> 且里面的字够多（≥200）就只取它；描述（meta description）不在正文里时放在最前面。
 */
function htmlToText(html) {
  const { title, description } = headOf(html);
  const lower = html.toLowerCase();
  let text = '';
  for (const tag of ['article', 'main']) {
    const a = lower.indexOf(`<${tag}`);
    const b = lower.lastIndexOf(`</${tag}`);
    if (a >= 0 && b > a) {
      const inner = stripTags(html.slice(a, b));
      if (inner.length >= 200) {
        text = inner;
        break;
      }
    }
  }
  if (!text) text = stripTags(html);
  if (description && !text.includes(description)) text = text ? `${description}\n${text}` : description;
  return { title, text };
}

/** input 标签里写着 type=password。只跑在一个标签（≤ MAX_TAG）上。 */
const PASSWORD_RE = /\btype\s*=[\s"']*password\b/;

/** 页面里有没有密码框：tagsOf 线性地挑出每个 <input …>，再在这一小段上看 type（为什么不对整页跑正则见 tagsOf）。 */
function hasPasswordInput(html) {
  const lower = html.toLowerCase();
  for (const [s, e] of tagsOf(lower, 'input')) if (PASSWORD_RE.test(lower.slice(s, e))) return true;
  return false;
}

/** 像不像登录墙：401 / 403、跳到了登录页的地址、正文不长又有密码框、正文很短又说「请登录」。便宜的条件先判。 */
function looksLikeLogin(status, finalUrl, html, text) {
  if (status === 401 || status === 403) return true;
  let u = null;
  try {
    u = new URL(finalUrl);
  } catch {
    u = null;
  }
  if (u && (/(^|\.)(login|passport|signin|sso|auth|account)\./i.test(u.hostname) || /\/(login|signin|sign-in|passport|sso|auth)(\/|$|\.|\?)/i.test(u.pathname))) return true;
  if (text.length < 2000 && hasPasswordInput(html)) return true;
  return text.length < 400 && /(登录|登陆|log ?in|sign ?in)/i.test(text);
}

// —— 主流程 ——

/**
 * 抓一个网页。返回 {url, finalUrl, title, text, chars, truncated, hint:null|'pdf'|'login'|'short', message}。
 * @param {string} raw
 * @param {{lookup?:Function, allowFakeIp?:boolean, timeoutMs?:number, maxBytes?:number, maxRedirects?:number, dial?:Function}} [opts]
 */
async function fetchPage(raw, opts = {}) {
  const { lookup = defaultLookup, allowFakeIp = false, timeoutMs = TIMEOUT_MS, maxBytes = MAX_BYTES, maxRedirects = MAX_REDIRECTS, dial = null } = opts;
  const first = parseTarget(raw, 'url');
  const ctl = new AbortController();
  const timeoutError = () => new HttpError(504, 'fetch_timeout', `${Math.round(timeoutMs / 1000)} 秒没抓完，网站太慢或者打不开。改用截图或复制粘贴吧`);
  const timer = setTimeout(() => ctl.abort(), timeoutMs);
  const aborted = new Promise((_, reject) => ctl.signal.addEventListener('abort', () => reject(timeoutError()), { once: true }));
  aborted.catch(() => {});
  const race = (p) => Promise.race([p, aborted]);
  try {
    let u = first;
    for (let hop = 0; ; hop++) {
      const checked = await resolveSafe(u, { lookup, allowFakeIp, race });
      const dialed = (address) => {
        const d = dial(address);
        return { address: d, family: net.isIP(d) };
      };
      const target = dial ? { ...checked, addresses: checked.addresses.map((a) => dialed(a.address)) } : checked;
      let res;
      try {
        res = await race(requestOnce(u, target, { signal: ctl.signal, maxBytes }));
      } catch (e) {
        if (e instanceof HttpError) throw e;
        if (ctl.signal.aborted) throw timeoutError();
        throw connectError(e, u);
      }
      if (res.redirect !== undefined) {
        if (!res.redirect) throw new HttpError(502, 'fetch_failed', `${u.host} 回了跳转（${res.status}）却没说跳到哪`);
        if (hop >= maxRedirects) throw new HttpError(502, 'too_many_redirects', `跳转超过 ${maxRedirects} 次，没抓到内容。改用截图或复制粘贴吧`);
        let next;
        try {
          next = parseTarget(new URL(res.redirect, u).href, 'url');
        } catch (e) {
          if (e instanceof HttpError) throw new HttpError(400, 'invalid_url', '这个网址跳到了不支持的地址（只能抓 http / https）');
          throw e;
        }
        u = next;
        continue;
      }
      return pageOf(first, u, res);
    }
  } finally {
    clearTimeout(timer);
  }
}

/** 读完的回应 → 结果。 */
function pageOf(first, u, res) {
  const base = { url: first.href, finalUrl: u.href };
  if (res.pdf) return { ...base, title: '', text: '', chars: 0, truncated: false, hint: 'pdf', message: HINT_MESSAGE.pdf };
  const { status } = res;
  if (status >= 400 && status !== 401 && status !== 403) {
    throw new HttpError(502, 'fetch_failed', status === 404 ? '这个网址打不开（404，页面不存在）' : `网站回了 ${status}，没抓到内容`);
  }
  const type = String(res.headers['content-type'] || '');
  if (res.unsupported) throw new HttpError(502, 'unsupported_page', `这个网址不是网页（${type.split(';')[0].trim()}），改用截图或复制粘贴吧`);
  const decoded = decodeBody(res.body, charsetOf(type, res.body));
  const isHtml = res.kind === 'html';
  const { title, text: full } = isHtml ? htmlToText(decoded) : { title: '', text: decoded.replace(/\r\n?/g, '\n').trim() };
  const truncated = full.length > MAX_TEXT;
  const text = truncated ? full.slice(0, MAX_TEXT) : full;
  let hint = null;
  if (looksLikeLogin(status, u.href, isHtml ? decoded : '', text)) hint = 'login';
  else if (text.length < SHORT_TEXT) hint = 'short';
  return { ...base, title, text, chars: text.length, truncated, hint, message: hint ? HINT_MESSAGE[hint] : null };
}

module.exports = {
  TIMEOUT_MS, MAX_BYTES, MAX_REDIRECTS, MAX_TEXT, SHORT_TEXT,
  FAKE_IP_COST,
  parseTarget, blockedReason, fetchPage, htmlToText, decodeBody, charsetOf, looksLikeLogin, connectError,
};
