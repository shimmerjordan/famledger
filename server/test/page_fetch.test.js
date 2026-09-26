'use strict';

// 网址抓取（lib/page_fetch.js，spec §4 POST /asset-import/fetch、§8 SSRF 矩阵）：不访问任何外部网站。
//   · 地址检查一律注入假 lookup（记下被问了哪些名字）：IP 直写的根本不该去问 DNS；
//   · 真要连的只有本机起的测试服务器：假 lookup 把 shop.test 解析成一个公网地址（检查照常过），dial 再把它换成 127.0.0.1。
// 钉死：127 / 10 / 169.254 / [::1] / ::ffff:127.0.0.1 / 解析到内网的域名 / 重定向到内网 / 超过 3 跳全拦（说明里不带解析出的地址）；
// fake-ip 段默认拦、可放开，放开时不收 IP 直写、单段主机名、内网后缀；几个解析结果第一个连不上接着试下一个；正文超过 2MB 中止、
// 总超时、GBK 页面、裸 deflate、登录墙（401 / 403 / 登录页地址 / 密码框 / 很短又说请登录）、PDF、正文提取、证书错误的中文说明；
// 2MB 的对抗页面（一大堆 `<input ` / `<meta ` 不闭合）线性处理，不卡事件循环。

const test = require('node:test');
const assert = require('node:assert/strict');
const http = require('node:http');
const zlib = require('node:zlib');

const { fetchPage, blockedReason, parseTarget, htmlToText, looksLikeLogin, connectError } = require('../src/lib/page_fetch');

const PUBLIC = '93.184.216.34';
const PUBLIC2 = '93.184.216.35';
const HOSTS = {
  'shop.test': [PUBLIC], 'passport.shop.test': [PUBLIC], 'intranet.test': ['10.0.0.8'], 'mixed.test': [PUBLIC, '192.168.1.10'],
  'fake.test': ['198.18.3.4'], 'v6.test': ['fd00::5'], 'multi.test': [PUBLIC2, PUBLIC],
};

/** 假 DNS：记下问过的名字；不认识的名字当解析不了。 */
function fakeLookup() {
  const asked = [];
  const lookup = async (host) => {
    asked.push(host);
    const list = HOSTS[host];
    if (!list) throw Object.assign(new Error(`getaddrinfo ENOTFOUND ${host}`), { code: 'ENOTFOUND' });
    return list.map((address) => ({ address, family: address.includes(':') ? 6 : 4 }));
  };
  return { lookup, asked };
}

/** 本机测试服务器：routes[path](req, res)；hits 记下每个请求的路径。 */
async function startSite(t, routes) {
  const hits = [];
  const server = http.createServer((req, res) => {
    hits.push(req.url);
    const route = routes[req.url.split('?')[0]];
    if (route) return route(req, res);
    res.writeHead(404, { 'content-type': 'text/html' });
    res.end('<h1>404</h1>');
  });
  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
  t.after(() => {
    server.closeAllConnections();
    return new Promise((resolve) => server.close(resolve));
  });
  const { port } = server.address();
  const { lookup, asked } = fakeLookup();
  const opts = { lookup, dial: () => '127.0.0.1' };
  return { port, hits, asked, opts, url: (p) => `http://shop.test:${port}${p}` };
}

const html = (res, body, headers = {}) => {
  res.writeHead(200, { 'content-type': 'text/html; charset=utf-8', ...headers });
  res.end(body);
};

async function rejectsWith(promise, code, status) {
  await assert.rejects(promise, (e) => {
    assert.equal(e.code, code, `${e.code}: ${e.message}`);
    if (status) assert.equal(e.status, status);
    return true;
  });
}

test('SSRF：IP 直写的回环、私网、链路本地、[::1]、::ffff:127.0.0.1、十进制和十六进制写法 → 400 url_blocked，不去问 DNS', async () => {
  const { lookup, asked } = fakeLookup();
  for (const u of [
    'http://127.0.0.1/', 'http://127.1.2.3:8080/x', 'http://10.1.2.3/', 'http://172.16.0.1/', 'http://192.168.1.1/', 'http://100.64.0.1/',
    'http://169.254.169.254/latest/meta-data/', 'http://[::1]/', 'http://[::ffff:127.0.0.1]/', 'http://[fd00::1]/', 'http://[fe80::1]/',
    'http://0.0.0.0/', 'http://2130706433/', 'http://0x7f000001/', 'https://[::]/',
  ]) {
    await rejectsWith(fetchPage(u, { lookup }), 'url_blocked', 400);
  }
  assert.deepEqual(asked, []);
});

test('SSRF：解析到内网的域名拦下（几个结果里有一个是内网也拦）；fake-ip 段默认拦并说明 URL_FETCH_ALLOW_FAKEIP，放开后能抓', async (t) => {
  const site = await startSite(t, { '/': (req, res) => html(res, `<p>${'会员权益说明，每月领 4 张券。'.repeat(8)}</p>`) });
  const { lookup } = site.opts;
  await assert.rejects(fetchPage(`http://intranet.test:${site.port}/`, site.opts), (e) => {
    assert.deepEqual([e.code, e.details, e.blockedAddress], ['url_blocked', { fakeIp: false }, '10.0.0.8']);
    assert.ok(!e.message.includes('10.0.0.8'), '说明里不带解析出的内网地址');
    return true;
  });
  await rejectsWith(fetchPage(`http://mixed.test:${site.port}/`, site.opts), 'url_blocked');
  await rejectsWith(fetchPage(`http://v6.test:${site.port}/`, site.opts), 'url_blocked');
  await assert.rejects(fetchPage(`http://fake.test:${site.port}/`, site.opts), (e) => {
    assert.deepEqual([e.code, e.details], ['url_blocked', { fakeIp: true }]);
    assert.match(e.message, /URL_FETCH_ALLOW_FAKEIP=1/);
    assert.match(e.message, /重启/);
    assert.match(e.message, /核实不了|没法核实/);
    assert.ok(!e.message.includes('198.18.3.4'));
    return true;
  });
  assert.deepEqual(site.hits, [], '被拦的一个请求都没发出去');
  const page = await fetchPage(`http://fake.test:${site.port}/`, { lookup, dial: () => '127.0.0.1', allowFakeIp: true });
  assert.match(page.text, /每月领 4 张券/);
  await rejectsWith(fetchPage(`http://nowhere.test:${site.port}/`, site.opts), 'dns_failed', 502);
});

test('放开 fake-ip 时：DNS 回的是假地址、核实不了真实目标，只抓带域名的公网网址 —— IP 直写、单段主机名、内网后缀都拦，连 DNS 都不问；跳转过去也拦', async (t) => {
  let port = 0;
  const site = await startSite(t, {
    '/': (req, res) => html(res, `<p>${'会员权益说明，每月领 4 张券。'.repeat(8)}</p>`),
    '/to-nas': (req, res) => {
      res.writeHead(302, { location: `http://nas:${port}/` });
      res.end();
    },
  });
  port = site.port;
  const { lookup, asked } = fakeLookup();
  const opts = { lookup, dial: () => '127.0.0.1', allowFakeIp: true };
  for (const u of [
    `http://${PUBLIC}:${port}/`, `http://[2606:4700::1111]:${port}/`, `http://nas:${port}/`, `http://db/`, `http://router.lan/`, `http://printer.local/`,
    `http://x.home.arpa/`, `http://svc.internal/`, `http://box.localdomain/`, `http://a.b.home/`, `http://localhost:${port}/`,
  ]) {
    await rejectsWith(fetchPage(u, opts), 'url_blocked', 400);
  }
  assert.deepEqual(asked, [], '不对就连 DNS 都不问（不给人借服务端的 DNS 探内网主机名）');
  assert.match((await fetchPage(`http://fake.test:${port}/`, opts)).text, /每月领 4 张券/);
  await rejectsWith(fetchPage(`http://fake.test:${port}/to-nas`, opts), 'url_blocked');
  assert.deepEqual(site.hits, ['/', '/to-nas'], '被拦的一个请求都没发出去');
});

test('几个解析结果都检查过：第一个连不上接着试下一个（钉死的 lookup 把全部地址交给 Node）', async (t) => {
  const site = await startSite(t, { '/': (req, res) => html(res, `<p>${'第二个地址上的正文。'.repeat(10)}</p>`) });
  // 第一个地址「连到」127.0.0.2（没人在听 → 拒绝连接），第二个才是测试服务器。
  const opts = { lookup: site.opts.lookup, dial: (address) => (address === PUBLIC2 ? '127.0.0.2' : '127.0.0.1') };
  assert.match((await fetchPage(`http://multi.test:${site.port}/`, opts)).text, /第二个地址上的正文/);
});

test('SSRF：重定向到内网域名、到 127.0.0.1 都拦，内网那页一次都没被请求；3 跳能到，第 4 跳 too_many_redirects；跳到 file: 不跟', async (t) => {
  let port = 0;
  const redirect = (to) => (req, res) => {
    res.writeHead(302, { location: typeof to === 'function' ? to() : to });
    res.end();
  };
  const site = await startSite(t, {
    '/to-intranet': redirect(() => `http://intranet.test:${port}/secret`),
    '/to-loopback': redirect(() => `http://127.0.0.1:${port}/secret`),
    '/to-file': redirect('file:///etc/passwd'),
    '/r4': redirect('/r3'),
    '/r3': redirect('/r2'),
    '/r2': redirect('/r1'),
    '/r1': redirect('/page'),
    '/page': (req, res) => html(res, `<title>到了</title><p>${'终于到了正文。'.repeat(12)}</p>`),
    '/secret': (req, res) => html(res, '内网的秘密'),
  });
  port = site.port;
  await rejectsWith(fetchPage(site.url('/to-intranet'), site.opts), 'url_blocked');
  await rejectsWith(fetchPage(site.url('/to-loopback'), site.opts), 'url_blocked');
  await rejectsWith(fetchPage(site.url('/to-file'), site.opts), 'invalid_url');
  assert.ok(!site.hits.includes('/secret'), site.hits.join(','));
  const ok = await fetchPage(site.url('/r3'), site.opts);
  assert.deepEqual([ok.title, ok.finalUrl], ['到了', site.url('/page')]);
  site.hits.length = 0;
  await rejectsWith(fetchPage(site.url('/r4'), site.opts), 'too_many_redirects', 502);
  assert.deepEqual(site.hits, ['/r4', '/r3', '/r2', '/r1'], '第 4 次跳转就不再跟');
});

test('写法：只收 http / https，不带用户名密码；没写协议按 https；#锚点去掉', async () => {
  for (const u of ['ftp://shop.test/', 'file:///etc/passwd', 'javascript:alert(1)', 'http://user:pass@shop.test/', '', '   ', 'http://', `https://x.test/${'a'.repeat(2000)}`]) {
    assert.throws(() => parseTarget(u), (e) => e.code === 'invalid_url', u.slice(0, 40));
  }
  assert.throws(() => parseTarget(42), (e) => e.code === 'invalid_url');
  assert.equal(parseTarget('mp.weixin.qq.com/s/abc#top').href, 'https://mp.weixin.qq.com/s/abc');
  assert.equal(parseTarget(' HTTP://Shop.Test/a?b=1 ').href, 'http://shop.test/a?b=1');
});

test('体积上限：正文超过 2MB 立刻中止（服务端没发完就被断开）；声明超限的不读；gzip 解压后超限同样中止', async (t) => {
  const chunk = Buffer.alloc(64 * 1024, 'a');
  let sent = 0;
  let closedEarly = false;
  const site = await startSite(t, {
    '/huge': async (req, res) => {
      res.writeHead(200, { 'content-type': 'text/plain' });
      res.on('close', () => {
        if (!res.writableFinished) closedEarly = true;
      });
      for (let i = 0; i < 128 && !res.destroyed; i++) {
        await new Promise((resolve) => res.write(chunk, resolve));
        sent += chunk.length;
      }
      res.end();
    },
    '/declared': (req, res) => {
      res.writeHead(200, { 'content-type': 'text/html', 'content-length': String(5 * 1024 * 1024) });
      res.write('<p>只发一点</p>');
    },
    '/bomb': (req, res) => {
      res.writeHead(200, { 'content-type': 'text/html', 'content-encoding': 'gzip' });
      res.end(zlib.gzipSync(Buffer.alloc(3 * 1024 * 1024, 'b')));
    },
    '/gzip': (req, res) => {
      res.writeHead(200, { 'content-type': 'text/html; charset=utf-8', 'content-encoding': 'gzip' });
      res.end(zlib.gzipSync(Buffer.from(`<p>${'压缩过的正文。'.repeat(20)}</p>`)));
    },
    '/deflate': (req, res) => {
      res.writeHead(200, { 'content-type': 'text/html; charset=utf-8', 'content-encoding': 'deflate' });
      res.end(zlib.deflateSync(Buffer.from(`<p>${'带 zlib 头的正文。'.repeat(20)}</p>`)));
    },
    '/rawdeflate': (req, res) => {
      res.writeHead(200, { 'content-type': 'text/html; charset=utf-8', 'content-encoding': 'deflate' });
      res.end(zlib.deflateRawSync(Buffer.from(`<p>${'裸 deflate 的正文。'.repeat(20)}</p>`)));
    },
    '/rawbomb': (req, res) => {
      res.writeHead(200, { 'content-type': 'text/html', 'content-encoding': 'deflate' });
      res.end(zlib.deflateRawSync(Buffer.alloc(3 * 1024 * 1024, 'c')));
    },
  });
  await rejectsWith(fetchPage(site.url('/huge'), site.opts), 'page_too_large', 502);
  await new Promise((resolve) => setTimeout(resolve, 100));
  assert.ok(closedEarly, '客户端读到上限就断开了');
  assert.ok(sent < 128 * chunk.length, `服务端只发出去 ${sent} 字节`);
  const started = Date.now();
  await rejectsWith(fetchPage(site.url('/declared'), site.opts), 'page_too_large');
  assert.ok(Date.now() - started < 2000);
  await rejectsWith(fetchPage(site.url('/bomb'), site.opts), 'page_too_large');
  assert.match((await fetchPage(site.url('/gzip'), site.opts)).text, /压缩过的正文/);
  // Content-Encoding: deflate 带不带 zlib 头都认（浏览器两种都收）；裸 deflate 的炸弹照样在 2MB 处中止。
  assert.match((await fetchPage(site.url('/deflate'), site.opts)).text, /带 zlib 头的正文/);
  assert.match((await fetchPage(site.url('/rawdeflate'), site.opts)).text, /裸 deflate 的正文/);
  await rejectsWith(fetchPage(site.url('/rawbomb'), site.opts), 'page_too_large');
});

test('超时：不回应的、一点一点挤牙膏的，都在总时限内掐断 → 504 fetch_timeout', async (t) => {
  const site = await startSite(t, {
    '/hang': () => {},
    '/slow': (req, res) => {
      res.writeHead(200, { 'content-type': 'text/html' });
      const timer = setInterval(() => res.write('<p>慢</p>'), 50);
      res.on('close', () => clearInterval(timer));
    },
  });
  for (const p of ['/hang', '/slow']) {
    const started = Date.now();
    await rejectsWith(fetchPage(site.url(p), { ...site.opts, timeoutMs: 300 }), 'fetch_timeout', 504);
    assert.ok(Date.now() - started < 1500, `${p} 用了 ${Date.now() - started}ms`);
  }
});

/** 「腾讯视频VIP会员：每月领 4 张观影券，有效期至 2026-12-31」的 GBK 编码。 */
const GBK_LINE = Buffer.from('ccdad1b6cad3c6b5564950bbe1d4b1a3bac3bfd4c2c1ec203420d5c5b9dbd3b0c8afa3acd3d0d0a7c6dad6c120323032362d31322d3331', 'hex');
/** 「会员中心」 */
const GBK_TITLE = Buffer.from('bbe1d4b1d6d0d0c4', 'hex');

test('编码：<meta charset=gbk>、Content-Type 的 charset=gb2312、http-equiv 都按 GBK 解；UTF-8 BOM 照认', async (t) => {
  const gbkPage = (meta) => Buffer.concat([
    Buffer.from(`<html><head>${meta}<title>`, 'latin1'), GBK_TITLE, Buffer.from('</title></head><body><p>', 'latin1'),
    GBK_LINE, Buffer.from('</p><p>', 'latin1'), GBK_LINE, Buffer.from('</p></body></html>', 'latin1'),
  ]);
  const site = await startSite(t, {
    '/meta': (req, res) => {
      res.writeHead(200, { 'content-type': 'text/html' });
      res.end(gbkPage('<meta charset="gbk">'));
    },
    '/header': (req, res) => {
      res.writeHead(200, { 'content-type': 'text/html; charset=GB2312' });
      res.end(gbkPage(''));
    },
    '/equiv': (req, res) => {
      res.writeHead(200, { 'content-type': 'text/html' });
      res.end(gbkPage('<meta http-equiv="Content-Type" content="text/html; charset=gbk">'));
    },
    '/bom': (req, res) => {
      res.writeHead(200, { 'content-type': 'text/plain' });
      res.end(Buffer.concat([Buffer.from([0xef, 0xbb, 0xbf]), Buffer.from('京东PLUS 年卡 ¥198，每月 5 张运费券。'.repeat(3))]));
    },
  });
  for (const p of ['/meta', '/header', '/equiv']) {
    const page = await fetchPage(site.url(p), site.opts);
    assert.equal(page.title, '会员中心', p);
    assert.match(page.text, /腾讯视频VIP会员：每月领 4 张观影券，有效期至 2026-12-31/, p);
  }
  const bom = await fetchPage(site.url('/bom'), site.opts);
  assert.ok(bom.text.startsWith('京东PLUS 年卡 ¥198'));
});

test('正文提取：去掉脚本、样式、导航、页脚、注释，块级换行、实体解开；有够长的 <article> 只取它；描述放最前', async () => {
  const body = [
    '<!doctype html><html><head><title>88VIP &amp; 权益</title><meta name="description" content="淘宝 88VIP 年卡权益一览">',
    '<style>p{color:red}</style><script>var a = "<p>不要我</p>";</script></head><body>',
    '<nav><a href="/">首页</a><a href="/me">我的</a></nav><!-- 注释 <p>也不要</p> -->',
    '<div>每月 2 张观影券<br>饿了么超级会员&nbsp;年卡</div><ul><li>优酷年卡</li><li>网易云音乐年卡</li></ul>',
    '<table><tr><td>价格</td><td>&yen;88</td></tr></table><p>1 &lt; 2，满 99 减 10</p>',
    '<footer>© 淘宝</footer></body></html>',
  ].join('');
  const { title, text } = htmlToText(body);
  assert.equal(title, '88VIP & 权益');
  assert.equal(text, '淘宝 88VIP 年卡权益一览\n每月 2 张观影券\n饿了么超级会员 年卡\n· 优酷年卡\n· 网易云音乐年卡\n价格 ¥88\n1 < 2，满 99 减 10');
  const withArticle = htmlToText(`<header>站点导航很长很长</header><article><h1>权益说明</h1><p>${'每月领 4 张券，领取后 30 天内有效。'.repeat(12)}</p></article><div>猜你喜欢</div>`);
  assert.ok(withArticle.text.startsWith('权益说明\n每月领 4 张券'));
  assert.ok(!withArticle.text.includes('猜你喜欢') && !withArticle.text.includes('站点导航'));
  // 没闭合的 <script> 到文末都跳过，不会卡住。
  assert.equal(htmlToText('<p>前面</p><script>while(true){}').text, '前面');
});

test('登录墙：有密码框的短页面、401、403、被跳到 /login 或 passport. 开头的主机、正文很短又说「请登录」的 → hint login；PDF（按 Content-Type 或开头的 %PDF-）→ hint pdf', async (t) => {
  let port = 0;
  const site = await startSite(t, {
    '/wall': (req, res) => html(res, '<title>登录</title><form><input name="u"><input type="password" name="p"><button>登录</button></form>'),
    '/401': (req, res) => {
      res.writeHead(401, { 'content-type': 'text/html' });
      res.end('<p>Unauthorized</p>');
    },
    '/member': (req, res) => {
      res.writeHead(302, { location: '/login?redirect=%2Fmember' });
      res.end();
    },
    '/login': (req, res) => html(res, `<p>${'欢迎回来，扫码或者输入手机号继续。'.repeat(5)}</p>`),
    '/to-passport': (req, res) => {
      res.writeHead(302, { location: `http://passport.shop.test:${port}/qr` });
      res.end();
    },
    '/qr': (req, res) => html(res, `<p>${'打开 App 扫一扫，继续访问会员中心。'.repeat(5)}</p>`),
    '/403': (req, res) => {
      res.writeHead(403, { 'content-type': 'text/html' });
      res.end(`<p>${'没有权限访问这个页面。'.repeat(8)}</p>`);
    },
    '/please': (req, res) => html(res, `<p>${'会员中心的内容很丰富，'.repeat(20)}请登录后查看全部权益。</p>`),
    '/doc.pdf': (req, res) => {
      res.writeHead(200, { 'content-type': 'application/pdf' });
      res.end('%PDF-1.7 ...');
    },
    '/download': (req, res) => {
      res.writeHead(200, { 'content-type': 'application/octet-stream' });
      res.end('%PDF-1.4 ...');
    },
  });
  port = site.port;
  for (const p of ['/wall', '/401', '/member', '/to-passport', '/403', '/please']) {
    const page = await fetchPage(site.url(p), site.opts);
    assert.equal(page.hint, 'login', p);
    assert.match(page.message, /要登录/);
  }
  // 正文够长的普通页面提到「登录」不算登录墙。
  assert.equal(looksLikeLogin(200, 'https://shop.test/rights', '<p>x</p>', `${'权益说明。'.repeat(100)}登录后领取`), false);
  for (const p of ['/doc.pdf', '/download']) {
    const page = await fetchPage(site.url(p), site.opts);
    assert.deepEqual([page.hint, page.text, page.chars], ['pdf', '', 0], p);
    assert.match(page.message, /PDF/);
  }
});

test('其他：图片 → unsupported_page（不读正文）；404 → fetch_failed；正文太短 → hint short；超过 20000 字截断', async (t) => {
  const site = await startSite(t, {
    '/img.png': (req, res) => {
      res.writeHead(200, { 'content-type': 'image/png' });
      res.end(Buffer.alloc(1024));
    },
    '/bin': (req, res) => {
      res.writeHead(200, { 'content-type': 'application/octet-stream' });
      res.end(Buffer.alloc(1024, 1));
    },
    '/tiny': (req, res) => html(res, '<div id="app"></div><script src="/app.js"></script>'),
    '/long': (req, res) => html(res, `<p>${'权'.repeat(25000)}</p>`),
    '/ok': (req, res) => html(res, `<title>京东 PLUS</title><p>${'PLUS 会员每月 5 张运费券，年卡 198 元。'.repeat(4)}</p>`),
  });
  await rejectsWith(fetchPage(site.url('/img.png'), site.opts), 'unsupported_page', 502);
  await rejectsWith(fetchPage(site.url('/bin'), site.opts), 'unsupported_page');
  await rejectsWith(fetchPage(site.url('/missing'), site.opts), 'fetch_failed', 502);
  const tiny = await fetchPage(site.url('/tiny'), site.opts);
  assert.deepEqual([tiny.hint, tiny.text], ['short', '']);
  const long = await fetchPage(site.url('/long'), site.opts);
  assert.deepEqual([long.chars, long.truncated, long.hint], [20000, true, null]);
  const ok = await fetchPage(site.url('/ok'), site.opts);
  assert.deepEqual(
    { ...ok, text: undefined },
    { url: site.url('/ok'), finalUrl: site.url('/ok'), title: '京东 PLUS', text: undefined, chars: ok.text.length, truncated: false, hint: null, message: null },
  );
});

test('ReDoS：2MB 的对抗页面（一大堆 `<input ` / `<meta ` 不闭合、超长空白）—— 判登录墙、提取正文都是线性的，200ms 内完', () => {
  // 原来的 /<input\b[^>]*type=password/ 对这种页面是 O(n²)：400KB 就要 8 秒，2MB 要几分钟，整个服务端跟着卡住。
  const N = 2 * 1024 * 1024;
  const rep = (piece) => piece.repeat(Math.ceil(N / piece.length)).slice(0, N);
  const pages = {
    input: rep('<input '), meta: rep('<meta '), inputType: `<input type=${' '.repeat(N)}`, metaDesc: `<meta name=description content="${'x'.repeat(N)}`,
    shared: `${rep('<input <meta ')}>`, charset: `<meta charset=${' '.repeat(N)}`,
  };
  for (const [name, page] of Object.entries(pages)) {
    const started = process.hrtime.bigint();
    const { text } = htmlToText(page);
    const login = looksLikeLogin(200, 'https://shop.test/', page, text);
    const ms = Number(process.hrtime.bigint() - started) / 1e6;
    assert.ok(ms < 200, `${name}：${ms.toFixed(1)}ms`);
    assert.equal(login, false, name);
  }
  // 标签照常认：大小写、单双引号、没有引号。
  assert.equal(looksLikeLogin(200, 'https://shop.test/', '<form><INPUT Type=\'Password\' name=p></form>', '登'), true);
  assert.equal(looksLikeLogin(200, 'https://shop.test/', '<input type=passwords><input name=type value=password>', '登'), false);
  assert.equal(htmlToText('<meta property="og:description" content=\'权益一览\'><p>正文</p>').text, '权益一览\n正文');
});

test('ReDoS（端到端）：服务器回 2MB 的 `<input ` 页面，fetchPage 很快回来，事件循环没被卡住', async (t) => {
  const body = '<input '.repeat(Math.floor((2 * 1024 * 1024 - 64) / 7));
  const site = await startSite(t, { '/evil': (req, res) => html(res, body) });
  const started = Date.now();
  let lag = 0;
  const timer = setTimeout(() => {
    lag = Date.now() - started - 50;
  }, 50);
  const page = await fetchPage(site.url('/evil'), site.opts);
  await new Promise((resolve) => setTimeout(resolve, 60));
  clearTimeout(timer);
  assert.equal(page.hint, 'short');
  assert.ok(Date.now() - started < 1500, `用了 ${Date.now() - started}ms`);
  assert.ok(lag < 500, `50ms 的定时器晚了 ${lag}ms`);
});

test('证书错误（含证书链不完整）一律给中文说明，不回显 Node 的英文原话', () => {
  const u = new URL('https://shop.test/');
  for (const code of ['UNABLE_TO_VERIFY_LEAF_SIGNATURE', 'UNABLE_TO_GET_ISSUER_CERT_LOCALLY', 'SELF_SIGNED_CERT_IN_CHAIN', 'DEPTH_ZERO_SELF_SIGNED_CERT', 'CERT_HAS_EXPIRED', 'ERR_TLS_CERT_ALTNAME_INVALID', 'HOSTNAME_MISMATCH']) {
    const e = connectError(Object.assign(new Error('unable to verify the first certificate; if the root CA is installed locally, try running Node.js with --use-system-ca'), { code }), u);
    assert.deepEqual([e.status, e.code], [502, 'fetch_failed'], code);
    assert.match(e.message, /证书有问题/, code);
    assert.ok(!e.message.includes('Node.js'), code);
  }
  assert.match(connectError(Object.assign(new Error('x'), { code: 'ECONNREFUSED' }), u).message, /拒绝连接/);
});

test('blockedReason 表驱动：各种内网、保留、嵌着内网 IPv4 的 IPv6 都拦；公网放行；fake-ip 可放开', () => {
  const cases = [
    ['127.0.0.1', 'loopback'], ['10.255.0.1', 'private'], ['172.31.255.255', 'private'], ['172.32.0.1', null], ['192.168.0.1', 'private'],
    ['100.64.0.1', 'private'], ['169.254.1.1', 'link_local'], ['0.0.0.0', 'reserved'], ['224.0.0.1', 'multicast'], ['255.255.255.255', 'reserved'],
    ['198.18.0.1', 'fake_ip'], ['198.19.255.255', 'fake_ip'], ['198.20.0.1', null], [PUBLIC, null],
    ['::1', 'loopback'], ['::', 'reserved'], ['::ffff:127.0.0.1', 'mapped'], ['::ffff:7f00:1', 'mapped'], ['::ffff:8.8.8.8', 'mapped'],
    ['::127.0.0.1', 'mapped'], ['fd12:3456::1', 'private'], ['fe80::1%eth0', 'link_local'], ['ff02::1', 'multicast'],
    ['64:ff9b::a00:1', 'private'], ['64:ff9b::5db8:d822', null], ['2002:c0a8:0101::1', 'private'], ['2606:4700::1111', null], ['not-an-ip', 'reserved'],
  ];
  for (const [address, why] of cases) assert.equal(blockedReason(address), why, address);
  assert.equal(blockedReason('198.18.0.1', { allowFakeIp: true }), null);
  assert.equal(blockedReason('10.0.0.1', { allowFakeIp: true }), 'private');
});
