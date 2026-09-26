'use strict';

// 截图导入的纯函数部分（spec §6「截图」「抽取管线」「依据核对」）：图片守门（文件头、单张 3.75MB、每边 1..2000 —— PNG 读 IHDR
// 并走通块结构、JPEG 找 SOF、WebP 读 VP8/VP8L/VP8X —— 最多 8 片），截图模式的提示词（第几块、img），规范化时每条带 img（出自第几块）、
// 不逐条标「依据未核实」（预览顶上整批说一次）、关键字段进 unverified（落库后是「AI 推断」小点）、和示例同名就标「疑似照抄示例」。

const test = require('node:test');
const assert = require('node:assert/strict');

const { readImages, sniff, pngSize, jpegSize, webpSize, MAX_IMAGE_BYTES } = require('../src/lib/perk_import_image');
const { buildImportPrompt } = require('../src/lib/perk_import_prompt');
const { normalizeImport } = require('../src/lib/perk_import_normalize');
const { pngBuffer, pngImage } = require('./import_fixtures');

/** 最小的 JPEG 头：SOI + APP0(JFIF) + SOF0（w×h，3 分量）+ 一点数据。[sof] 为假时不带 SOF 段（直接 SOS）。 */
function jpegBuffer(w, h, { sof = true, marker = 0xc0 } = {}) {
  const app0 = Buffer.concat([Buffer.from([0xff, 0xe0, 0x00, 0x10]), Buffer.from('JFIF\0', 'latin1'), Buffer.from([1, 1, 0, 0, 1, 0, 1, 0, 0])]);
  const sof0 = Buffer.alloc(19);
  sof0.writeUInt16BE(0xff00 | marker, 0);
  sof0.writeUInt16BE(17, 2);
  sof0[4] = 8;
  sof0.writeUInt16BE(h, 5);
  sof0.writeUInt16BE(w, 7);
  sof0[9] = 3;
  const sos = Buffer.from([0xff, 0xda, 0x00, 0x08, 1, 1, 0, 0, 0x3f, 0]);
  return Buffer.concat([Buffer.from([0xff, 0xd8]), app0, ...(sof ? [sof0] : []), sos, Buffer.alloc(16), Buffer.from([0xff, 0xd9])]);
}

/** 最小的 WebP 头：RIFF + WEBP + 一个 VP8 / VP8L / VP8X 块（只填尺寸相关的字节）。 */
function webpBuffer(kind, w, h) {
  const chunk = Buffer.alloc(30);
  if (kind === 'VP8 ') {
    chunk.set([0x9d, 0x01, 0x2a], 3);
    chunk.writeUInt16LE(w, 6);
    chunk.writeUInt16LE(h, 8);
  } else if (kind === 'VP8L') {
    chunk[0] = 0x2f;
    chunk.writeUInt32LE(((w - 1) & 0x3fff) | (((h - 1) & 0x3fff) << 14), 1);
  } else {
    chunk.writeUIntLE(w - 1, 4, 3);
    chunk.writeUIntLE(h - 1, 7, 3);
  }
  const size = Buffer.alloc(4);
  size.writeUInt32LE(chunk.length, 0);
  const riff = Buffer.alloc(4);
  riff.writeUInt32LE(12 + chunk.length, 0);
  return Buffer.concat([Buffer.from('RIFF'), riff, Buffer.from('WEBP'), Buffer.from(kind, 'latin1'), size, chunk]);
}

const b64 = (buf) => ({ data: buf.toString('base64') });

const codeOf = (fn) => {
  try {
    fn();
  } catch (e) {
    return [e.status, e.code, e.message];
  }
  return null;
};

test('守门：PNG / JPEG / WebP 按文件头认（不信请求里写的类型），三种都读出宽高；data: 前缀剥掉', () => {
  const png = pngBuffer(784, 1568);
  assert.equal(sniff(png), 'image/png');
  assert.deepEqual(pngSize(png), { width: 784, height: 1568 });
  const jpeg = jpegBuffer(1080, 1920);
  const webp = webpBuffer('VP8 ', 640, 1280);
  const out = readImages([
    { mediaType: 'image/jpeg', data: png.toString('base64') },
    b64(jpeg),
    { data: `data:image/webp;base64,${webp.toString('base64')}` },
  ]);
  assert.deepEqual(out.map((i) => [i.mediaType, i.width, i.height]), [['image/png', 784, 1568], ['image/jpeg', 1080, 1920], ['image/webp', 640, 1280]]);
  assert.equal(out[0].bytes, png.length);
  assert.equal(out[2].data, webp.toString('base64'), '转给上游的是去掉前缀的 base64');
});

test('守门：JPEG 找 SOF 段（渐进式 SOF2 也认）、WebP 三种头都读得出尺寸；读不出的回 null', () => {
  assert.deepEqual(jpegSize(jpegBuffer(1200, 900)), { width: 1200, height: 900 });
  assert.deepEqual(jpegSize(jpegBuffer(1200, 900, { marker: 0xc2 })), { width: 1200, height: 900 });
  assert.equal(jpegSize(jpegBuffer(1200, 900, { sof: false })), null, 'SOS 之前没有 SOF');
  assert.equal(jpegSize(Buffer.from([0xff, 0xd8, 0xff, 0xe0, 0x00, 0x40, 1, 2])), null, '段长度超出文件');
  assert.deepEqual(webpSize(webpBuffer('VP8 ', 1000, 2000)), { width: 1000, height: 2000 });
  assert.deepEqual(webpSize(webpBuffer('VP8L', 1500, 700)), { width: 1500, height: 700 });
  assert.deepEqual(webpSize(webpBuffer('VP8X', 3000, 4000)), { width: 3000, height: 4000 });
  const broken = webpBuffer('VP8 ', 10, 10);
  broken[23] = 0; // 起始码不对
  assert.equal(webpSize(broken), null);
});

test('守门：没有图、超过 8 片、不是 base64、认不出的文件、单张超过 3.75MB、PNG 边长超过 2000 —— 都是 400 invalid_images 且说清第几张', () => {
  const gif = Buffer.from('GIF89a' + '\0'.repeat(30), 'latin1');
  const huge = Buffer.concat([pngBuffer(10, 10), Buffer.alloc(MAX_IMAGE_BYTES)]);
  const cases = [
    [undefined, /至少选一张截图/],
    [[], /至少选一张截图/],
    [Array.from({ length: 9 }, () => pngImage(10, 10)), /最多 8 片/],
    [[pngImage(10, 10), { data: '这不是base64!!' }], /第 2 张图的数据坏了/],
    [[{ data: gif.toString('base64') }], /第 1 张不是 PNG、JPEG 或 WebP/],
    [[{ data: huge.toString('base64') }], /第 1 张图有 3\.75\d*MB|单张不能超过 3\.75MB/],
    [[pngImage(1080, 2160)], /第 1 张图是 1080×2160，每边不能超过 2000 像素/],
    [['plain-string-not-object'], /第 1 张图的数据坏了|不是 PNG/],
    [[{ data: '' }], /第 1 张图没有数据/],
    // 只读头也要挡住上游一定会拒的：JPEG / WebP 同样每边 ≤2000，宽高是 0 的、读不出尺寸的、PNG 头对但后面是垃圾的
    [[b64(jpegBuffer(9000, 9000))], /第 1 张图是 9000×9000，每边不能超过 2000 像素/],
    [[b64(webpBuffer('VP8X', 2500, 1000))], /第 1 张图是 2500×1000/],
    [[b64(jpegBuffer(0, 100))], /第 1 张图的尺寸是 0×100，文件坏了/],
    [[b64(jpegBuffer(100, 100, { sof: false }))], /第 1 张 JPEG 的文件坏了/],
    [[b64(pngBuffer(0, 0))], /尺寸是 0×0/],
    [[b64(Buffer.concat([pngBuffer(10, 10).subarray(0, 33), Buffer.from('这后面全是垃圾'.repeat(4))]))], /第 1 张 PNG 的文件坏了/],
  ];
  for (const [raw, re] of cases) {
    const got = codeOf(() => readImages(raw));
    assert.ok(got, `${JSON.stringify(raw)?.slice(0, 60)} 应该 400`);
    assert.deepEqual(got.slice(0, 2), [400, 'invalid_images']);
    assert.match(got[2], re);
  }
  assert.equal(readImages([pngImage(2000, 2000)]).length, 1, '正好 2000 可以');
});

test('截图模式的提示词：同样的已有名字和识别范围，说明第几块、要写 img；不带原文的 <<< >>>', () => {
  const p = buildImportPrompt({ want: 'items', existing: { platforms: ['淘宝'] } });
  const text = p.userForImages(4);
  assert.match(text, /这次只抽 item/);
  assert.match(text, /已有的平台.*淘宝/);
  assert.match(text, /按顺序附的 4 张截图（第 1 块 … 第 4 块）/);
  assert.match(text, /"img"/);
  assert.ok(!text.includes('<<<'));
});

test('规范化（截图来源）：img 只认 1..块数；不逐条标「依据未核实」、不压置信度、不做 span；关键字段（有值的）进 unverified、字段置信度 ≤0.6；N 选 1 的父权益用第一个选项的块；和示例同名的标照抄且不勾', () => {
  const records = [
    { t: 'platform', name: '淘宝', ev: '88VIP', conf: 0.9, img: 1 },
    { t: 'membership', name: '88VIP', platform: '淘宝', fee: 88, expiresOn: '2026-12-31', ev: '年费 88 元', conf: 0.9, img: '1' },
    { t: 'benefit', name: '优酷视频年卡', membership: '88VIP', claimPlatform: '优酷', quota: [{ p: 'term', n: 1 }], ev: '优酷视频年卡', conf: 0.9, img: 2 },
    { t: 'benefit', name: '网易云音乐黑胶年卡', membership: '88VIP', choice: { group: '三选一', pick: 1 }, ev: '三选一', img: 3 },
    { t: 'benefit', name: 'QQ 音乐年卡', membership: '88VIP', choice: { group: '三选一', pick: 1 }, ev: 'QQ', img: 9 },
    { t: 'item', name: '声澜 Z3 降噪耳机', category: 'digital', price: 899, purchasedOn: '2026-03-08', ev: '声澜 Z3', img: 0 },
  ];
  const d = normalizeImport(records, { sourceKind: 'image', imageCount: 3, today: '2026-09-23' });
  const by = (list, name) => list.find((n) => n.fields.name === name);
  assert.deepEqual([by(d.platforms, '淘宝').img, by(d.memberships, '88VIP').img], [1, 1]);
  assert.equal(by(d.platforms, '优酷').img, 2, '补建的领取平台用带出它的那条的块');
  assert.equal(by(d.benefits, 'QQ 音乐年卡').img, null, '块号超出范围当没写');
  assert.equal(by(d.benefits, '三选一').img, 3);
  const item = d.items[0];
  assert.equal(item.img, null, '0 不是合法块号');
  for (const n of [...d.platforms, ...d.memberships, ...d.benefits, ...d.items]) {
    assert.ok(!n.badges.includes('ev_unverified'), `${n.fields.name} 不该逐条标依据未核实（「需确认」会变成全部）`);
    assert.ok(!n.badges.includes('claim_unsure'));
    assert.equal(n.span, null);
  }
  const card = by(d.memberships, '88VIP');
  assert.equal(card.conf, 0.9, '截图来源不压节点置信度');
  assert.deepEqual(card.unverified, ['expiresOn', 'feeCents'], '有值的关键字段；autoRenew 没写（unknown）、termStartOn 为空的不算');
  assert.deepEqual(card.fieldConf, { expiresOn: 0.6, feeCents: 0.6 });
  assert.deepEqual(by(d.benefits, '优酷视频年卡').unverified, ['claimPlatformId', 'quota']);
  assert.deepEqual(by(d.benefits, '网易云音乐黑胶年卡').unverified, [], '选项的额度是空的、没写领取平台');
  assert.deepEqual(item.unverified, ['priceCents', 'purchasedOn']);
  assert.deepEqual(by(d.platforms, '淘宝').unverified, [], '平台没有关键字段');
  assert.ok(item.badges.includes('copied_example') && item.checked === false, '示例里编的名字出现在截图结果里 → 疑似照抄');

  const text = normalizeImport(records, { sourceKind: 'text', source: '淘宝 88VIP 年费 88 元', today: '2026-09-23' });
  assert.ok(text.platforms.every((p) => p.img === null), '文字来源一律没有 img');
});
