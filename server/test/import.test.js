'use strict';

// 表格导入预览（支付宝 / 微信 / 通用模板）与批量改删。夹具由
// fixtures/import/make_fixtures.py 生成；xlsx 的边角情况在这里手拼最小 zip。

const test = require('node:test');
const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const fs = require('node:fs');
const path = require('node:path');
const zlib = require('node:zlib');
const { DatabaseSync } = require('node:sqlite');

const { household } = require('./fixtures');
const { readTable, excelSerialToDate } = require('../src/lib/sheet');
const nb = require('../src/lib/nb');
const { NB_SEED } = require('../src/modules/seed');

const FIX = path.join(__dirname, 'fixtures', 'import');
const fixture = (name) => fs.readFileSync(path.join(FIX, name));
const clientIdOf = (basis) => `imp-${crypto.createHash('sha1').update(basis).digest('hex').slice(0, 16)}`;

function preview(h, filename, data) {
  return h.a.post('/import/preview', { filename, data: Buffer.from(data).toString('base64') }, h.auth);
}

/** 只写 xlsx 读取需要的那几样：本地头、中央目录、目录尾。 */
function zip(entries) {
  const locals = [];
  const centrals = [];
  let offset = 0;
  for (const e of entries) {
    const raw = Buffer.isBuffer(e.data) ? e.data : Buffer.from(e.data, 'utf8');
    const method = e.store ? 0 : 8;
    const body = e.store ? raw : zlib.deflateRawSync(raw);
    const name = Buffer.from(e.name, 'utf8');
    const crc = zlib.crc32(raw);
    const local = Buffer.alloc(30);
    local.writeUInt32LE(0x04034b50, 0);
    local.writeUInt16LE(20, 4);
    local.writeUInt16LE(e.flags || 0, 6);
    local.writeUInt16LE(method, 8);
    local.writeUInt32LE(crc, 14);
    local.writeUInt32LE(body.length, 18);
    local.writeUInt32LE(raw.length, 22);
    local.writeUInt16LE(name.length, 26);
    const central = Buffer.alloc(46);
    central.writeUInt32LE(0x02014b50, 0);
    central.writeUInt16LE(20, 4);
    central.writeUInt16LE(20, 6);
    central.writeUInt16LE(e.flags || 0, 8);
    central.writeUInt16LE(method, 10);
    central.writeUInt32LE(crc, 16);
    central.writeUInt32LE(body.length, 20);
    // 声明的解压大小可以撒谎：炸弹用例故意写小。
    central.writeUInt32LE(e.claimedSize ?? raw.length, 24);
    central.writeUInt16LE(name.length, 28);
    central.writeUInt32LE(offset, 42);
    locals.push(local, name, body);
    centrals.push(central, name);
    offset += 30 + name.length + body.length;
  }
  const cd = Buffer.concat(centrals);
  const end = Buffer.alloc(22);
  end.writeUInt32LE(0x06054b50, 0);
  end.writeUInt16LE(entries.length, 8);
  end.writeUInt16LE(entries.length, 10);
  end.writeUInt32LE(cd.length, 12);
  end.writeUInt32LE(offset, 16);
  return Buffer.concat([...locals, cd, end]);
}

const NS = 'http://schemas.openxmlformats.org/spreadsheetml/2006/main';
const RNS = 'http://schemas.openxmlformats.org/officeDocument/2006/relationships';

function xlsx({ sheet, shared = null, workbookPr = '', target = 'worksheets/sheet1.xml', extra = [] }) {
  const entries = [
    { name: '[Content_Types].xml', data: '<?xml version="1.0" encoding="UTF-8"?><Types/>' },
    {
      name: 'xl/workbook.xml',
      data: `<?xml version="1.0" encoding="UTF-8"?><workbook xmlns="${NS}" xmlns:r="${RNS}">${workbookPr}` +
        '<sheets><sheet name="账单" sheetId="1" r:id="rId1"/></sheets></workbook>',
    },
    {
      name: 'xl/_rels/workbook.xml.rels',
      data: '<?xml version="1.0" encoding="UTF-8"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">' +
        `<Relationship Id="rId1" Type="${RNS}/worksheet" Target="${target}"/></Relationships>`,
    },
    { name: 'xl/worksheets/sheet1.xml', data: Buffer.isBuffer(sheet) ? sheet : `<worksheet xmlns="${NS}"><sheetData>${sheet}</sheetData></worksheet>` },
    ...extra,
  ];
  if (shared) entries.push({ name: 'xl/sharedStrings.xml', data: `<sst xmlns="${NS}">${shared.join('')}</sst>` });
  return zip(entries);
}

const inl = (ref, text) => `<c r="${ref}" t="inlineStr"><is><t>${text}</t></is></c>`;
const num = (ref, n) => `<c r="${ref}"><v>${n}</v></c>`;
const sst = (ref, i) => `<c r="${ref}" t="s"><v>${i}</v></c>`;
const row = (r, cells) => `<row r="${r}">${cells.join('')}</row>`;

function assertUnsupported(fn, pattern) {
  assert.throws(fn, (e) => {
    assert.equal(e.status, 400);
    assert.equal(e.code, 'unsupported_file');
    if (pattern) assert.match(e.message, pattern);
    return true;
  });
}

// ── lib/sheet.js ─────────────────────────────────────────────────────────

test('sheet: CSV 引号/转义/字段内换行、制表符分隔、去首尾空白', () => {
  const csv = 'a,b,c\r\n" x ","he said ""hi""","line1\nline2"\n  1\t, 2 ,\r\n';
  assert.deepEqual(readTable(Buffer.from(csv)).rows, [
    ['a', 'b', 'c'],
    ['x', 'he said "hi"', 'line1\nline2'],
    ['1', '2', ''],
  ]);
  // 只有制表符的行多于逗号时才当 TSV：每个字段里的逗号不会被拆开。
  assert.deepEqual(readTable(Buffer.from('日期\t金额\t备注\n2026-09-12\t1,234.50\t早饭，午饭\n')).rows, [
    ['日期', '金额', '备注'],
    ['2026-09-12', '1,234.50', '早饭，午饭'],
  ]);
});

test('sheet: UTF-8 BOM / GBK / UTF-16LE 都能读出中文', () => {
  const bom = Buffer.concat([Buffer.from([0xef, 0xbb, 0xbf]), Buffer.from('日期,金额\n')]);
  assert.deepEqual(readTable(bom).rows, [['日期', '金额']]);

  const gbk = fixture('alipay_gbk.csv');
  assert.throws(() => new TextDecoder('utf-8', { fatal: true }).decode(gbk), '夹具确实不是 UTF-8');
  const rows = readTable(gbk).rows;
  const header = rows.find((r) => r[0] === '交易时间');
  assert.ok(header, '按 GBK 解出了表头');
  assert.deepEqual(header.slice(0, 12), ['交易时间', '交易分类', '交易对方', '对方账号', '商品说明', '收/支', '金额', '收/付款方式', '交易状态', '交易订单号', '商家订单号', '备注']);
  const first = rows[rows.indexOf(header) + 1];
  assert.equal(first[9], '2026091522001100001', '订单号后面的制表符被去掉');

  const utf16 = Buffer.concat([Buffer.from([0xff, 0xfe]), Buffer.from('日期\t金额\r\n2026-09-12\t5\r\n', 'utf16le')]);
  assert.deepEqual(readTable(utf16).rows, [['日期', '金额'], ['2026-09-12', '5']]);
});

test('sheet: excelSerialToDate 覆盖 1900 闰年错与 1904 系统', () => {
  assert.equal(excelSerialToDate(46277), '2026-09-12 00:00:00');
  assert.equal(excelSerialToDate(46277.520833333336), '2026-09-12 12:30:00');
  assert.equal(excelSerialToDate('46278.75'), '2026-09-13 18:00:00');
  assert.equal(excelSerialToDate(1), '1900-01-01 00:00:00');
  assert.equal(excelSerialToDate(59), '1900-02-28 00:00:00');
  assert.equal(excelSerialToDate(61), '1900-03-01 00:00:00');
  assert.equal(excelSerialToDate(0, true), '1904-01-01 00:00:00');
  assert.equal(excelSerialToDate(0), null);
  assert.equal(excelSerialToDate('abc'), null);
  assert.equal(excelSerialToDate(1e9), null);
});

test('sheet: XLSX 共享字符串/富文本/内联/数字/布尔/公式缓存值/空列', () => {
  const shared = [
    '<si><t>日期</t></si>',
    '<si><r><rPr><b/></rPr><t>金</t></r><r><t xml:space="preserve">额</t></r><rPh sb="0" eb="1"><t>きん</t></rPh></si>',
    '<si><t>A &amp; B &lt;&#x4E2D;&#25991;&gt;_x000D_</t></si>',
    '<si/>',
  ];
  const sheet =
    row(1, [sst('A1', 0), sst('B1', 1), inl('D1', '备注')]) +
    row(3, [
      num('A3', 46277.5), num('B3', 35.5), '<c r="C3" t="b"><v>1</v></c>',
      '<c r="D3" t="str"><f>A1&amp;B1</f><v>公式缓存</v></c>', '<c r="E3" t="e"><v>#N/A</v></c>', sst('F3', 2), sst('G3', 3),
    ]) +
    '<row r="4"/>' +
    '<row r="5"><c r="B5" s="1"/><c r="XFD5"><v>太远的列被丢掉</v></c></row>';
  const { rows, date1904, truncated } = readTable(xlsx({ sheet, shared, workbookPr: '<workbookPr date1904="1"/>' }), 'a.xlsx');
  assert.equal(date1904, true);
  assert.equal(truncated, false);
  // 空格子只在它右边还有值时才补位；整行都空（第 4、5 行）直接不出现。
  assert.deepEqual(rows, [
    ['日期', '金额', '', '备注'],
    ['46277.5', '35.5', 'TRUE', '公式缓存', '', 'A & B <中文>'],
  ]);
  // 没写 r 的格子按出现顺序占列，中间的空格子也占一列。
  assert.deepEqual(readTable(xlsx({ sheet: '<row><c t="inlineStr"><is><t>a</t></is></c><c/><c><v>3</v></c></row>' })).rows, [['a', '', '3']]);
});

test('sheet: 标签带命名空间前缀、rels 用绝对路径也能找到第一张表', () => {
  const entries = [
    { name: 'xl/workbook.xml', data: `<x:workbook xmlns:x="${NS}" xmlns:r="${RNS}"><x:sheets><x:sheet name="S" sheetId="9" r:id="rId7"/></x:sheets></x:workbook>` },
    { name: 'xl/_rels/workbook.xml.rels', data: '<Relationships><Relationship Id="rId7" Target="/xl/worksheets/data.xml"/></Relationships>' },
    { name: 'xl/worksheets/sheet1.xml', data: `<worksheet><sheetData><row r="1"><c r="A1" t="inlineStr"><is><t>错的表</t></is></c></row></sheetData></worksheet>` },
    { name: 'xl/worksheets/data.xml', data: `<x:worksheet xmlns:x="${NS}"><x:sheetData><x:row r="1"><x:c r="A1" t="inlineStr"><x:is><x:t>对的表</x:t></x:is></x:c></x:row></x:sheetData></x:worksheet>`, store: true },
  ];
  assert.deepEqual(readTable(zip(entries)).rows, [['对的表']]);
});

test('sheet: 畸形文件与 zip 炸弹 → 400 unsupported_file，不抛别的异常', () => {
  assertUnsupported(() => readTable(Buffer.alloc(0)), /空/);
  assertUnsupported(() => readTable(Buffer.from('PK\x03\x04 这不是真的 zip')), /损坏/);
  const good = xlsx({ sheet: row(1, [inl('A1', 'x')]) });
  assertUnsupported(() => readTable(good.subarray(0, good.length - 30)), /损坏/);
  assertUnsupported(() => readTable(Buffer.from([0xd0, 0xcf, 0x11, 0xe0, 0xa1, 0xb1, 0x1a, 0xe1, 0, 0])), /\.xls/);
  assertUnsupported(() => readTable(Buffer.from([0x25, 0x50, 0x44, 0x46, 0x00, 0x01, 0x02])), /不是表格/);
  assertUnsupported(() => readTable(Buffer.from('日期,金额\n'), 'bill.xlsx'), /损坏/);
  assertUnsupported(() => readTable(zip([{ name: 'alipay_record.csv', data: 'x' }])), /解压/);
  assertUnsupported(() => readTable(zip([{ name: 'xl/workbook.xml', data: '<workbook/>', flags: 1 }])), /密码/);

  // 60MB 的空格压成几十 KB，还谎报成 100 字节。
  const bomb = xlsx({ sheet: Buffer.alloc(60 * 1024 * 1024, 0x20) });
  assert.ok(bomb.length < 1024 * 1024, `炸弹本身很小（${bomb.length} 字节）`);
  assertUnsupported(() => readTable(bomb), /50MB/);
  const liar = zip([
    { name: 'xl/workbook.xml', data: '<workbook/>' },
    { name: 'xl/worksheets/sheet1.xml', data: Buffer.alloc(51 * 1024 * 1024, 0x20), claimedSize: 100 },
  ]);
  assertUnsupported(() => readTable(liar), /50MB/);
});

/** 在同步阻塞的解析上挂计时：修之前这些输入要卡住进程几十秒到几小时。 */
function assertFast(fn, label, ms = 2000) {
  const t = process.hrtime.bigint();
  const out = fn();
  const took = Number(process.hrtime.bigint() - t) / 1e6;
  assert.ok(took < ms, `${label} 用了 ${Math.round(took)}ms`);
  return out;
}

test('sheet: 没闭合的标签是线性时间判损坏，不会平方级回溯卡住进程', () => {
  const N = 100000;
  const cases = {
    row: xlsx({ sheet: '<row>'.repeat(N) }),
    c: xlsx({ sheet: `<row>${'<c>'.repeat(N)}</row>` }),
    v: xlsx({ sheet: `<row><c>${'<v>'.repeat(N)}</c></row>` }),
    is: xlsx({ sheet: `<row><c t="inlineStr">${'<is>'.repeat(N)}</c></row>` }),
    si: xlsx({ sheet: '', shared: ['<si>'.repeat(N)] }),
    t: xlsx({ sheet: '', shared: [`<si>${'<t>'.repeat(N)}</si>`] }),
    rPh: xlsx({ sheet: '', shared: [`<si>${'<rPh>'.repeat(N)}</si>`] }),
    sheetData: xlsx({ sheet: Buffer.from(`<worksheet>${'<sheetData>'.repeat(N)}</worksheet>`) }),
    sheet: zip([{ name: 'xl/workbook.xml', data: `<workbook>${'<sheet'.repeat(N)}` }]),
    workbookPr: zip([
      { name: 'xl/workbook.xml', data: `<workbook>${'<workbookPr'.repeat(N)}` },
      { name: 'xl/worksheets/sheet1.xml', data: '<worksheet/>' },
    ]),
    Relationship: zip([
      { name: 'xl/workbook.xml', data: `<workbook xmlns:r="${RNS}"><sheets><sheet r:id="rId1"/></sheets></workbook>` },
      { name: 'xl/_rels/workbook.xml.rels', data: '<Relationship'.repeat(N) },
    ]),
  };
  for (const [name, buf] of Object.entries(cases)) {
    assert.ok(buf.length < 8192, `${name} 的 zip 只有 ${buf.length} 字节`);
    assertFast(() => assertUnsupported(() => readTable(buf), /损坏/), `未闭合的 <${name}>`);
  }
});

test('sheet: 空格子不补位、非空行读满 maxRows 就停，小文件撑不爆内存', () => {
  // 每行 21 字节，修之前每行要补出 255 个空串。
  const blank = assertFast(() => readTable(xlsx({ sheet: '<row><c r="IU"/></row>'.repeat(300000) })), '30 万个空的远列格子');
  // 先比长度：修之前这里是 30 万行，deepEqual 生成差异要跑好几分钟。
  assert.equal(blank.rows.length, 0);
  assert.equal(blank.truncated, false);

  const wide = assertFast(() => readTable(xlsx({ sheet: '<row><c r="IU"><v>1</v></c></row>'.repeat(300000) }), 'a.xlsx', { maxRows: 100 }), '30 万行远列');
  assert.equal(wide.truncated, true);
  assert.equal(wide.rows.length, 100);
  assert.equal(wide.rows[0].length, 255);

  const exact = readTable(xlsx({ sheet: '<row><c r="A1"><v>1</v></c></row>'.repeat(100) }), 'a.xlsx', { maxRows: 100 });
  assert.deepEqual([exact.rows.length, exact.truncated], [100, false], '刚好装满不算截断');

  // 格子总数有上限：光扫空格子也要时间。
  assertUnsupported(() => readTable(xlsx({ sheet: `<row>${'<c/>'.repeat(1_000_001)}</row>` })), /太大/);
  assertUnsupported(() => readTable(xlsx({ sheet: '', shared: ['<si/>'.repeat(1_000_001)] })), /太大/);

  const csvBlank = assertFast(() => readTable(Buffer.from(`日期,金额\n${'\n'.repeat(3_000_000)}${',,\r\n'.repeat(100000)}`)), '300 万个空行');
  assert.equal(csvBlank.rows.length, 1);
  assert.deepEqual(csvBlank.rows, [['日期', '金额']]);
  const csvMany = readTable(Buffer.from(`日期,金额\n${'2026-09-12,1\n'.repeat(1000)}`), 'a.csv', { maxRows: 100 });
  assert.deepEqual([csvMany.rows.length, csvMany.truncated], [100, true]);
  const csvWide = readTable(Buffer.from(`${'a,'.repeat(300)}b\n`));
  assert.equal(csvWide.rows[0].length, 256, 'CSV 也只留前 256 列');
});

// ── POST /import/preview ────────────────────────────────────────────────

async function withAccounts(h) {
  const alipay = (await h.a.post('/accounts', { name: '支付宝', kind: 'alipay' }, h.auth)).json.account;
  const wechat = (await h.a.post('/accounts', { name: '微信钱包', kind: 'wechat' }, h.auth)).json.account;
  const bank = (await h.a.post('/accounts', { name: '招行卡', kind: 'bank', matchHints: { cardTails: ['8888'] } }, h.auth)).json.account;
  return { alipay, wechat, bank };
}

test('支付宝 GBK 账单：识别来源、跳过规则、账户猜测、稳定 clientId、重复导入 exists', async (t) => {
  const h = await household(t);
  const { alipay, bank } = await withAccounts(h);

  const r = await preview(h, 'alipay_record_20260916.csv', fixture('alipay_gbk.csv'));
  assert.equal(r.status, 200, r.text);
  const out = r.json;
  assert.equal(out.source, 'alipay');
  assert.equal(out.sourceLabel, '支付宝账单');
  assert.deepEqual([out.total, out.importable, out.skipped], [8, 4, 4], '说明文字与末尾汇总行都不算交易');
  assert.deepEqual(out.rows.map((x) => x.row), [1, 2, 3, 4, 5, 6, 7, 8]);
  assert.deepEqual(out.rows.map((x) => x.skip && x.skip.code), [null, null, null, 'neutral', 'closed', 'refund', null, 'invalid']);
  for (const x of out.rows.filter((y) => y.skip)) assert.ok(x.skip.message);

  const [meituan, didi, market, , , , friend] = out.rows;
  const { confidence, ...rest } = meituan;
  assert.deepEqual(
    rest,
    {
      row: 1,
      clientId: clientIdOf('alipay|2026091522001100001'),
      type: 'expense',
      amountCents: 3500,
      occurredAt: '2026-09-15T12:30:05+08:00',
      merchant: '美团',
      note: '美团订单-26091511100300001',
      rawCategory: '餐饮美食',
      categoryId: h.categories.find((c) => c.name === '餐饮').id,
      fundId: null,
      accountId: alipay.id,
      skip: null,
      exists: false,
      duplicateOf: null,
      hint: null,
    },
  );
  assert.ok(confidence > 0 && confidence <= 1, `confidence=${confidence}`);
  assert.equal(didi.note, '滴滴快车,早高峰', '引号里的逗号不拆列');
  assert.equal(didi.amountCents, 2350);
  assert.equal(didi.accountId, bank.id, '付款方式里的卡尾号命中 matchHints.cardTails');
  assert.equal(market.note, '超市购物 周末采购\n顺便买了水果', '备注接在商品说明后面，字段内换行保留');
  assert.equal(market.rawCategory, '日用百货');
  assert.equal(friend.type, 'income');
  assert.equal(friend.amountCents, 8800);
  // 种子模型一个字都不认识「李四」，只凭先验会猜成「理财」（约 0.04）：宁可留在「未分类」里。
  assert.deepEqual([friend.categoryId, friend.confidence], [null, null]);
  assert.equal(out.rows[3].amountCents, 50000, '跳过的行照样把内容摆出来');

  const importable = out.rows.filter((x) => !x.skip);
  const items = importable.map((x) => ({
    clientId: x.clientId, type: x.type, amountCents: x.amountCents, occurredAt: x.occurredAt,
    merchant: x.merchant, note: x.note, accountId: x.accountId, source: 'import',
  }));
  const first = await h.a.post('/transactions/batch', { items }, h.auth);
  assert.equal(first.status, 200, first.text);
  assert.deepEqual(first.json.results.map((x) => x.status), ['created', 'created', 'created', 'created']);
  assert.ok(first.json.results.every((x) => !x.duplicate), 'import 来源不走两分钟查重');

  const again = await preview(h, 'alipay_record_20260916.csv', fixture('alipay_gbk.csv'));
  assert.deepEqual(again.json.rows.map((x) => x.clientId), out.rows.map((x) => x.clientId), '同一文件 clientId 稳定');
  assert.deepEqual(again.json.rows.filter((x) => !x.skip).map((x) => x.exists), [true, true, true, true]);
  assert.deepEqual(again.json.rows.filter((x) => !x.skip).map((x) => x.duplicateOf), [null, null, null, null], '已导入的那条不算自己的重复');
  const second = await h.a.post('/transactions/batch', { items }, h.auth);
  assert.deepEqual(second.json.results.map((x) => x.status), ['exists', 'exists', 'exists', 'exists']);
  assert.equal((await h.a.get('/transactions?source=import', h.auth)).json.items.length, 4);
});

test('duplicateOf：同日同额同类型、商户相同或任一为空才算；已删的不算', async (t) => {
  const h = await household(t);
  const dupOf = async () => (await preview(h, 'a.csv', fixture('alipay_gbk.csv'))).json.rows[0].duplicateOf;

  await h.tx({ type: 'expense', amountCents: 3500, occurredAt: '2026-09-15T08:00:00+08:00', merchant: '肯德基' });
  await h.tx({ type: 'income', amountCents: 3500, occurredAt: '2026-09-15T09:00:00+08:00', merchant: '美团' });
  await h.tx({ type: 'expense', amountCents: 3500, occurredAt: '2026-09-14T12:30:05+08:00', merchant: '美团' });
  assert.equal(await dupOf(), null, '商户不同、类型不同、日期不同都不算');

  const same = (await h.tx({ type: 'expense', amountCents: 3500, occurredAt: '2026-09-15T21:00:00+08:00', merchant: '美团' })).json.transaction;
  assert.equal(await dupOf(), same.id);
  await h.a.del(`/transactions/${same.id}`, h.auth);
  assert.equal(await dupOf(), null);

  const blank = (await h.tx({ type: 'expense', amountCents: 3500, occurredAt: '2026-09-15T23:00:00+08:00' })).json.transaction;
  assert.equal(await dupOf(), blank.id, '已有流水没写商户也算可能重复');
});

test('微信账单：CSV 与 xlsx（交易时间是日期序列号）读出同样的结果', async (t) => {
  const h = await household(t);
  const { wechat, bank } = await withAccounts(h);

  const csv = await preview(h, '微信支付账单.csv', fixture('wechat.csv'));
  const book = await preview(h, '微信支付账单.xlsx', fixture('wechat.xlsx'));
  for (const r of [csv, book]) {
    assert.equal(r.status, 200, r.text);
    assert.equal(r.json.source, 'wechat');
    assert.equal(r.json.sourceLabel, '微信账单');
    assert.deepEqual([r.json.total, r.json.importable, r.json.skipped], [7, 3, 4]);
    assert.deepEqual(r.json.rows.map((x) => x.skip && x.skip.code), [null, null, null, 'neutral', 'refund', 'refund', 'refund']);
  }
  const strip = (rows) => rows.map((x) => ({ ...x }));
  assert.deepEqual(strip(book.json.rows), strip(csv.json.rows), '两种格式逐字段一致，clientId 也一样');

  const [breakfast, fruit, redPacket] = csv.json.rows;
  assert.equal(breakfast.clientId, clientIdOf('wechat|4200002026091500001'));
  assert.equal(breakfast.occurredAt, '2026-09-15T07:45:12+08:00');
  assert.equal(breakfast.amountCents, 1200, '¥12.00');
  assert.equal(breakfast.note, '包子豆浆', '备注是「/」时不拼进去');
  assert.equal(breakfast.rawCategory, '商户消费');
  assert.equal(breakfast.accountId, wechat.id);
  assert.equal(fruit.accountId, bank.id);
  assert.equal(redPacket.type, 'income');
  assert.equal(redPacket.merchant, '小红');
  assert.equal(redPacket.note, '', '「/」当空');
  assert.equal(redPacket.accountId, wechat.id);
});

const TEMPLATE_ROWS = [
  '日期,收支,金额,类别,基金,账户,备注',
  '2026-09-12,支出,35.00,餐饮,家庭公共基金,现金,午饭',
  '2026/9/13 18:30,收入,"8,000",工资,,,九月工资',
  '2026-09-14 07:05:09,收入,-12.5,不存在的类别,没这个基金,没这个账户,早餐',
  '2026-09-16,收入,5,其他,,,零钱利息',
  '昨天,支出,10,,,,坏日期',
  '2026-09-15,支出,abc,,,,坏金额',
  '2026-09-15,支出,0,,,,零',
  ',,,,,,',
  '2026-09-12,支出,¥35.00,餐饮,,,午饭',
  '20260917,支出,1.5,,,,八位日期',
  '2026-02-30,支出,1,,,,不存在的日期',
];

test('通用模板：名称精确匹配与 hint、负数当支出、日期格式、同键第 n 次', async (t) => {
  const h = await household(t);
  const cat = (name, kind) => h.categories.find((c) => c.name === name && c.kind === kind).id;
  const cash = h.accounts.find((a) => a.name === '现金');

  const r = await preview(h, 'template.csv', TEMPLATE_ROWS.join('\n'));
  assert.equal(r.status, 200, r.text);
  assert.equal(r.json.source, 'template');
  assert.equal(r.json.sourceLabel, '通用模板');
  assert.deepEqual([r.json.total, r.json.importable, r.json.skipped], [10, 6, 4], '空行不算');
  const rows = r.json.rows;
  assert.deepEqual(rows.map((x) => x.skip && x.skip.code), [null, null, null, null, 'invalid', 'invalid', 'invalid', null, null, 'invalid']);

  const [lunch, salary, weird, interest, , , , lunch2, eightDigits] = rows;
  assert.deepEqual(
    [lunch.type, lunch.amountCents, lunch.occurredAt, lunch.categoryId, lunch.fundId, lunch.accountId, lunch.note, lunch.hint],
    ['expense', 3500, '2026-09-12T12:00:00+08:00', cat('餐饮', 'expense'), h.fund.id, cash.id, '午饭', null],
  );
  assert.equal(lunch.rawCategory, '餐饮');
  assert.equal(lunch.clientId, clientIdOf('template|2026-09-12T12:00:00+08:00|3500||午饭|1'));
  assert.equal(lunch2.clientId, clientIdOf('template|2026-09-12T12:00:00+08:00|3500||午饭|2'), '同键第二次出现换一个 clientId');

  assert.deepEqual([salary.type, salary.amountCents, salary.occurredAt, salary.categoryId], ['income', 800000, '2026-09-13T18:30:00+08:00', cat('工资', 'income')]);
  assert.deepEqual([weird.type, weird.amountCents, weird.fundId, weird.accountId], ['expense', 1250, null, null], '负数金额一律当支出');
  assert.equal(weird.hint, '类别「不存在的类别」不存在；基金「没这个基金」不存在；账户「没这个账户」不存在');
  assert.equal(weird.categoryId, cat('餐饮', 'expense'), '写的类别对不上就交给模型：备注「早餐」种子认得');
  assert.ok(weird.confidence > 0 && weird.confidence <= 1);
  assert.equal(interest.categoryId, cat('其他', 'income'), '同名类别按收支挑');
  assert.equal(eightDigits.occurredAt, '2026-09-17T12:00:00+08:00');
  assert.equal(eightDigits.amountCents, 150);
  assert.match(rows[4].skip.message, /日期/);
  assert.match(rows[5].skip.message, /金额/);
  assert.equal(rows[4].occurredAt, null);
  assert.equal(rows[5].amountCents, null);

  // 两笔一模一样的午饭都得入账：import 来源不走两分钟查重，幂等只靠 clientId。
  const items = rows.filter((x) => !x.skip).map((x) => ({
    clientId: x.clientId, type: x.type, amountCents: x.amountCents, occurredAt: x.occurredAt, note: x.note,
    categoryId: x.categoryId, fundId: x.fundId, accountId: x.accountId, source: 'import',
  }));
  const res = (await h.a.post('/transactions/batch', { items }, h.auth)).json.results;
  assert.deepEqual(res.map((x) => x.status), Array(6).fill('created'));
  assert.ok(res.every((x) => !x.duplicate));
  const listed = (await h.a.get('/transactions?source=import', h.auth)).json.items;
  assert.equal(listed.filter((x) => x.note === '午饭').length, 2);
  assert.ok(listed.every((x) => x.status === 'confirmed'));
});

test('通用模板：同名类别只有反方向的时不挂上，hint 说明原因', async (t) => {
  const h = await household(t);
  const cat = (name, kind) => h.categories.find((c) => c.name === name && c.kind === kind).id;
  assert.ok(!h.categories.some((c) => c.name === '工资' && c.kind === 'expense'), '种子里「工资」只有收入类别');

  const csv = ['日期,收支,金额,类别', '2026-09-12,支出,10,工资', '2026-09-12,收入,10,工资', '2026-09-12,支出,10,餐饮'].join('\n');
  const r = await preview(h, 't.csv', csv);
  assert.equal(r.status, 200, r.text);
  const [wrong, right, meal] = r.json.rows;
  assert.deepEqual([wrong.type, wrong.skip], ['expense', null]);
  assert.equal(wrong.hint, '类别「工资」是收入类别，这笔是支出');
  // 种子模型会顺手猜一个，但只会是支出类别，绝不是那个「工资」。
  assert.equal(h.categories.find((c) => c.id === wrong.categoryId)?.kind ?? 'expense', 'expense');
  assert.deepEqual([right.categoryId, right.hint], [cat('工资', 'income'), null]);
  assert.deepEqual([meal.categoryId, meal.hint], [cat('餐饮', 'expense'), null]);
});

test('通用模板 xlsx：Excel 日期序列号、数字金额的浮点尾巴', async (t) => {
  const h = await household(t);
  const shared = ['<si><t>日期</t></si>', '<si><t>收支</t></si>', '<si><t>金额</t></si>', '<si><t>支出</t></si>'];
  const sheet =
    row(1, [sst('A1', 0), sst('B1', 1), sst('C1', 2), inl('D1', '类别'), inl('G1', '备注')]) +
    row(2, [num('A2', 46277), sst('B2', 3), num('C2', 35.5), inl('D2', '餐饮'), inl('G2', '整数序列号')]) +
    row(3, [num('A3', 46278.75), sst('B3', 3), num('C3', 35.499999999999), inl('G3', '带时间')]) +
    row(4, [inl('A4', '2026-09-14 08:00'), sst('B4', 3), inl('C4', '12'), inl('G4', '文本日期')]);
  const r = await preview(h, '模板.xlsx', xlsx({ sheet, shared }));
  assert.equal(r.status, 200, r.text);
  assert.equal(r.json.source, 'template');
  assert.deepEqual(
    r.json.rows.map((x) => [x.occurredAt, x.amountCents, x.note, x.skip]),
    [
      ['2026-09-12T12:00:00+08:00', 3550, '整数序列号', null],
      ['2026-09-13T18:00:00+08:00', 3550, '带时间', null],
      ['2026-09-14T08:00:00+08:00', 1200, '文本日期', null],
    ],
  );
  assert.equal(r.json.rows[0].categoryId, h.categories.find((c) => c.name === '餐饮').id);
});

test('认不出的表格、畸形文件、zip 炸弹 → 400 且服务还活着；行数上限 too_many_rows', async (t) => {
  const h = await household(t);
  const expect400 = async (res, code, pattern) => {
    assert.equal(res.status, 400, res.text);
    assert.equal(res.json.error.code, code);
    if (pattern) assert.match(res.json.error.message, pattern);
  };

  await expect400(await preview(h, 'x.csv', 'hello,world\n1,2\n'), 'unsupported_file', /支付宝账单、微信账单和通用模板/);
  const late = [...Array.from({ length: 41 }, (_, i) => `说明第 ${i} 行`), '日期,金额', '2026-09-12,5'].join('\n');
  await expect400(await preview(h, 'x.csv', late), 'unsupported_file', /认不出/);
  await expect400(await preview(h, 'x.xlsx', Buffer.from('PK\x03\x04garbage')), 'unsupported_file');
  await expect400(await preview(h, 'x.xlsx', xlsx({ sheet: Buffer.alloc(60 * 1024 * 1024, 0x20) })), 'unsupported_file', /50MB/);
  await expect400(await h.a.post('/import/preview', { filename: 'x.csv' }, h.auth), 'invalid_data');
  await expect400(await h.a.post('/import/preview', { filename: 'x.csv', data: '这不是base64!' }, h.auth), 'invalid_data');
  await expect400(await h.a.post('/import/preview', { filename: 'x.csv', data: '' }, h.auth), 'invalid_data');
  assert.equal((await h.a.post('/import/preview', { data: 'YQ==' })).status, 401, '预览要登录');

  const body = (n) => ['日期,收支,金额,类别,基金,账户,备注', ...Array.from({ length: n }, (_, i) => `2026-09-12,支出,${i + 1},,,,第${i}笔`)].join('\n');
  await expect400(await preview(h, 'big.csv', body(5001)), 'too_many_rows', /5000/);
  // 读到 1 万个非空行就停，不再把整个文件物化出来。
  await expect400(await preview(h, 'huge.csv', body(10000)), 'too_many_rows', /最多导入 5000 行.*超过 10000 行/);
  // 几 KB 的 xlsx：没闭合的 <row> 修之前同步卡住整个进程半分钟，远列空格子修之前能撑出几 GB。
  const t0 = Date.now();
  await expect400(await preview(h, 'x.xlsx', xlsx({ sheet: '<row>'.repeat(200000) })), 'unsupported_file', /损坏/);
  assert.ok(Date.now() - t0 < 2000, `没闭合的 <row> 用了 ${Date.now() - t0}ms`);
  await expect400(await preview(h, 'x.xlsx', xlsx({ sheet: '<row><c r="IU"/></row>'.repeat(300000) })), 'unsupported_file', /认不出/);
  const ok = await preview(h, 'max.csv', body(5000));
  assert.equal(ok.status, 200, ok.text);
  assert.equal(ok.json.total, 5000);
  assert.equal(new Set(ok.json.rows.map((x) => x.clientId)).size, 5000);

  const health = await h.a.raw('GET', '/healthz');
  assert.equal(health.text, 'ok', '炸弹之后进程还在');
  assert.ok(!/at .*sheet\.js/.test(h.srv.stderr()), '畸形输入不该在日志里留下堆栈');
});

test('GET /import/template.csv：无需登录、带 BOM、下载头；拿回来预览能直接用', async (t) => {
  const h = await household(t);
  const r = await fetch(`${h.srv.base}/api/v1/import/template.csv`);
  assert.equal(r.status, 200);
  assert.equal(r.headers.get('content-type'), 'text/csv; charset=utf-8');
  assert.equal(r.headers.get('content-disposition'), 'attachment; filename="famledger-template.csv"');
  const bytes = Buffer.from(await r.arrayBuffer());
  assert.deepEqual([...bytes.subarray(0, 3)], [0xef, 0xbb, 0xbf]);
  const lines = bytes.subarray(3).toString('utf8').split('\r\n').filter(Boolean);
  assert.equal(lines[0], '日期,收支,金额,类别,基金,账户,备注');
  assert.equal(lines.length, 3, '表头 + 两行示例');

  const back = await preview(h, 'famledger-template.csv', bytes);
  assert.equal(back.status, 200, back.text);
  assert.equal(back.json.source, 'template');
  assert.equal(back.json.importable, 2);
  assert.ok(back.json.rows.every((x) => x.hint === null && x.categoryId), '示例里的类别/账户是默认就有的');
  assert.equal(back.json.rows[0].accountId, h.accounts.find((a) => a.name === '现金').id);
});

const ALIPAY_HEAD = '交易时间,交易分类,交易对方,对方账号,商品说明,收/支,金额,收/付款方式,交易状态,交易订单号,商家订单号,备注';
/** [交易对方, 交易分类, 收/支] → 一份最小的支付宝账单，订单号各不相同。 */
const alipayCsv = (rows) =>
  [ALIPAY_HEAD, ...rows.map(([merchant, rawCategory, dir], i) => `2026-09-20 10:00:00,${rawCategory},${merchant},/,,${dir},59.00,花呗,交易成功,B${i},,`)].join('\n');

// 交易分类挑一个不在映射表里的：这条只看模型，不让兜底掺进来。
const PET_CSV = [ALIPAY_HEAD, '2026-09-20 10:00:00,商业服务,喵星人小铺,/,冻干,支出,59.00,花呗,交易成功,A0001,,'].join('\n');

test('猜分类：模型可信才猜，只挑收支方向对得上的活类别；基金模型同理', async (t) => {
  const h = await household(t);
  const pet = h.categories.find((c) => c.name === '宠物').id;

  const before = (await preview(h, 'a.csv', PET_CSV)).json.rows[0];
  assert.deepEqual([before.categoryId, before.confidence], [null, null], '种子模型没见过这家店，后验不到 0.2 不填');

  const samples = Array.from({ length: 3 }, () => ({ text: '喵星人小铺', categoryId: pet }));
  assert.equal((await h.a.post('/model/learn', { samples }, h.auth)).status, 200);
  const guessed = (await preview(h, 'a.csv', PET_CSV)).json.rows[0];
  assert.equal(guessed.categoryId, pet);
  assert.ok(guessed.confidence > 0.5 && guessed.confidence <= 1, `confidence=${guessed.confidence}`);
  assert.equal(guessed.fundId, null, '基金模型还是空的');

  // 只有一个基金类：薄模型不可信。
  const one = Array.from({ length: 3 }, () => ({ text: '喵星人小铺', fundId: h.fund.id }));
  await h.a.post('/model/learn', { samples: one }, h.auth);
  assert.equal((await preview(h, 'a.csv', PET_CSV)).json.rows[0].fundId, null);

  const petFund = (await h.a.post('/funds', { name: '宠物基金', kind: 'goal' }, h.auth)).json.fund;
  const two = Array.from({ length: 6 }, () => ({ text: '喵星人小铺', fundId: petFund.id }));
  await h.a.post('/model/learn', { samples: two }, h.auth);
  assert.equal((await preview(h, 'a.csv', PET_CSV)).json.rows[0].fundId, petFund.id);

  // 模板里写明了类别就不猜；类别已归档则不再被猜中。
  const tpl = (await preview(h, 't.csv', '日期,金额,类别,备注\n2026-09-20,59,宠物,喵星人小铺\n')).json.rows[0];
  assert.equal(tpl.categoryId, pet);
  assert.equal(tpl.confidence, null);
  await h.a.patch(`/categories/${pet}`, { archived: true }, h.auth);
  const archived = (await preview(h, 'a.csv', PET_CSV)).json.rows[0];
  assert.notEqual(archived.categoryId, pet);
});

test('新家庭从没调过 /model：预览自己建出种子模型并存下，美团/滴滴照样猜得出', async (t) => {
  const h = await household(t);
  const cat = (name) => h.categories.find((c) => c.name === name && c.kind === 'expense').id;
  const db = new DatabaseSync(path.join(h.srv.dataDir, 'famledger.db'), { readOnly: true });
  t.after(() => db.close());
  const stored = () => db.prepare('SELECT key FROM model ORDER BY key').all().map((x) => x.key);
  assert.deepEqual(stored(), [], '还没有哪台设备拉过模型');

  const [meituan, didi] = (await preview(h, 'a.csv', fixture('alipay_gbk.csv'))).json.rows;
  assert.equal(meituan.categoryId, cat('餐饮'));
  assert.equal(didi.categoryId, cat('交通'));
  for (const x of [meituan, didi]) {
    // ≥0.5 且不是 0.6：是模型自己有把握，不是交易分类兜底给的。
    assert.ok(x.confidence >= 0.5 && x.confidence !== 0.6, `${x.merchant} confidence=${x.confidence}`);
  }

  assert.deepEqual(stored(), ['category', 'fund'], '和 GET /model 同一条懒初始化，建出来就存下');
  const m = (await h.a.get('/model', h.auth)).json;
  assert.equal(m.version, 1, '预览建种子不推高版本号，设备不会因此重拉');
  assert.ok(Object.keys(m.category.classes).includes(cat('餐饮')));
});

test('支付宝交易分类兜底：模型猜不出或没把握时按映射给默认类别，置信度 0.6', async (t) => {
  const h = await household(t);
  const cat = (name, kind = 'expense') => h.categories.find((c) => c.name === name && c.kind === kind)?.id;
  const csv = alipayCsv([
    ['阿福记', '餐饮美食', '支出'], // 种子模型没见过这家店
    ['喵星人小铺', '宠物', '支出'], // 模型没把握到 0.2，不猜
    ['滴滴出行', '餐饮美食', '支出'], // 模型有把握，不让位
    ['阿福记', '餐饮美食', '收入'], // 「餐饮」是支出类别
    ['阿福记', '转账红包', '支出'], // 不在映射表里
    ['阿福记', '__proto__', '支出'], // 文件里的任意字符串都不能读到原型上
    ['携程', '交通出行', '支出'], // 模型猜「旅行」但不到 0.5，交易分类更可靠
    ['携程', '商业服务', '支出'], // 同一家店没有映射：0.2~0.5 的猜测照样给
  ]);
  const run = async () => (await preview(h, 'a.csv', csv)).json.rows;

  const [unknown, pet, didi, income, transfer, proto, trip, tripUnmapped] = await run();
  assert.deepEqual([unknown.categoryId, unknown.confidence], [cat('餐饮'), 0.6]);
  assert.deepEqual([pet.categoryId, pet.confidence], [cat('宠物'), 0.6]);
  assert.equal(didi.categoryId, cat('交通'));
  assert.ok(didi.confidence >= 0.5 && didi.confidence !== 0.6, `confidence=${didi.confidence}`);
  for (const x of [income, transfer, proto]) {
    assert.deepEqual([x.categoryId, x.confidence], [null, null], `${x.rawCategory}/${x.type} 不该兜底，模型也没把握`);
  }
  assert.equal(tripUnmapped.categoryId, cat('旅行'));
  assert.ok(tripUnmapped.confidence >= 0.2 && tripUnmapped.confidence < 0.5, `confidence=${tripUnmapped.confidence}`);
  assert.deepEqual([trip.categoryId, trip.confidence], [cat('交通'), 0.6]);

  // 映射按名称找还在用的类别：归档、删除都不给；新建一个同名的又能用上。
  const food = cat('餐饮');
  assert.equal((await h.a.patch(`/categories/${food}`, { archived: true }, h.auth)).status, 200);
  const [archived] = await run();
  assert.deepEqual([archived.categoryId, archived.confidence], [null, null]);
  assert.equal((await h.a.del(`/categories/${food}`, h.auth)).status, 200);
  const [deleted] = await run();
  assert.deepEqual([deleted.categoryId, deleted.confidence], [null, null]);
  const again = (await h.a.post('/categories', { name: '餐饮', kind: 'expense' }, h.auth)).json.category;
  assert.deepEqual((await run()).slice(0, 1).map((x) => [x.categoryId, x.confidence]), [[again.id, 0.6]]);

  // 微信的「交易类型」是商户消费/转账/红包，不是消费分类，哪怕写成支付宝的分类名也不映射。
  const wechat = [
    '交易时间,交易类型,交易对方,商品,收/支,金额(元),支付方式,当前状态,交易单号,商户单号,备注',
    '2026-09-20 10:00:00,餐饮美食,阿福记,/,支出,¥59.00,零钱,支付成功,W1,/,/',
  ].join('\n');
  const [wx] = (await preview(h, 'w.csv', wechat)).json.rows;
  assert.equal(wx.rawCategory, '餐饮美食');
  assert.deepEqual([wx.categoryId, wx.confidence], [null, null]);
});

test('模型不可信时不猜，交易分类兜底照样生效', async (t) => {
  const h = await household(t);
  const food = h.categories.find((c) => c.name === '餐饮' && c.kind === 'expense');
  // 只留「餐饮」：种子只训出一个类，薄模型的后验没有意义。
  for (const c of h.categories) {
    if (c.id !== food.id) assert.equal((await h.a.del(`/categories/${c.id}`, h.auth)).status, 200);
  }
  const [mapped, unmapped] = (await preview(h, 'a.csv', alipayCsv([['美团', '餐饮美食', '支出'], ['美团', '商业服务', '支出']]))).json.rows;
  assert.deepEqual([mapped.categoryId, mapped.confidence], [food.id, 0.6]);
  assert.deepEqual([unmapped.categoryId, unmapped.confidence], [null, null], '种子认得美团，但一个类的模型不可信');
});

test('nb.predict 传入预先算好的词表与不传逐位一致', () => {
  const golden = nb.parse(JSON.stringify(require('./fixtures/nb_golden.json').model));
  const seed = nb.emptyModel();
  for (const s of NB_SEED) nb.learn(seed, nb.tokenize(s.text), s.category);
  const texts = ['美团外卖', '滴滴快车 早高峰', '喵星人小铺', '永辉超市', '', 'zzz', '九月工资'];
  for (const model of [golden, seed]) {
    const vocab = nb.vocabulary(model);
    for (const text of texts) {
      const tokens = nb.tokenize(text, nb.extrasFor({ merchant: text, direction: 'expense', amountCents: 5900, hour: 10, weekday: 7 }));
      assert.deepEqual(nb.predict(model, tokens, vocab), nb.predict(model, tokens), JSON.stringify(text));
    }
  }
  assert.deepEqual(nb.predict(nb.emptyModel(), ['a'], new Set()), [], '空模型照样返回 []');
});

// ── POST /transactions/bulk ─────────────────────────────────────────────

async function ledger(t) {
  const h = await household(t);
  const catA = h.categories[0];
  const catB = h.categories[1];
  const fund2 = (await h.a.post('/funds', { name: '旅行基金', kind: 'goal' }, h.auth)).json.fund;
  const acct2 = (await h.a.post('/accounts', { name: '招行卡', kind: 'bank' }, h.auth)).json.account;
  const mk = async (body) => {
    const r = await h.tx(body);
    assert.equal(r.status, 201, r.text);
    return r.json.transaction;
  };
  const e1 = await mk({ type: 'expense', amountCents: 100, categoryId: catA.id, accountId: h.account.id, merchant: '一' });
  const e2 = await mk({ type: 'expense', amountCents: 200, categoryId: catA.id, accountId: h.account.id, merchant: '二' });
  const t1 = await mk({
    type: 'transfer', amountCents: 300, accountId: h.account.id, toAccountId: acct2.id, fundId: h.fund.id, toFundId: fund2.id,
  });
  const get = async (id) => (await h.a.get(`/transactions/${id}`, h.auth)).json.transaction;
  const bulk = (body) => h.a.post('/transactions/bulk', body, h.auth);
  return { ...h, catA, catB, fund2, acct2, e1, e2, t1, get, bulk };
}

test('bulk 改：一次改多行，转账跳过类别/基金；每行新 seq 与 updatedAt', async (t) => {
  const h = await ledger(t);
  const before = Math.max(h.e1.seq, h.e2.seq, h.t1.seq);

  const r = await h.bulk({ ids: [h.e1.id, h.e2.id, h.t1.id, h.e1.id], patch: { categoryId: h.catB.id, fundId: h.fund2.id, memberId: h.member.id } });
  assert.equal(r.status, 200, r.text);
  assert.deepEqual(r.json, { updated: 3 }, '重复的 id 只算一次');

  const [e1, e2, t1] = await Promise.all([h.get(h.e1.id), h.get(h.e2.id), h.get(h.t1.id)]);
  for (const e of [e1, e2]) {
    assert.equal(e.categoryId, h.catB.id);
    assert.equal(e.fundId, h.fund2.id);
    assert.equal(e.accountId, h.account.id, '没给的字段不动');
  }
  assert.equal(t1.categoryId, null, '转账没有类别');
  assert.deepEqual([t1.fundId, t1.toFundId], [h.fund.id, h.fund2.id], '转账的基金对原样保留');
  const seqs = [e1.seq, e2.seq, t1.seq];
  assert.ok(seqs.every((s) => s > before), 'seq 都往前走了');
  assert.equal(new Set(seqs).size, 3, '每行各自一个 seq');
  assert.ok(e1.updatedAt > h.e1.updatedAt);

  const changes = await h.a.get(`/changes?since=${before}`, h.auth);
  assert.equal(changes.json.transactions.length, 3);

  const moved = await h.bulk({ ids: [h.e1.id, h.t1.id], patch: { accountId: h.account.id } });
  assert.equal(moved.status, 200, moved.text);

  const other = (await h.a.post('/accounts', { name: '备用金', kind: 'cash' }, h.auth)).json.account;
  const acct = await h.bulk({ ids: [h.e2.id, h.t1.id], patch: { accountId: other.id } });
  assert.equal(acct.status, 200, acct.text);
  assert.equal((await h.get(h.t1.id)).accountId, other.id, '转账的账户照改');
  assert.equal((await h.get(h.e2.id)).accountId, other.id);
});

test('bulk 事务回滚：任一行校验失败或不存在，前面改过的行一并撤回', async (t) => {
  const h = await ledger(t);

  // 转出改成与转入同一个账户 → 这一行违反转账约束，整批失败。
  const clash = await h.bulk({ ids: [h.e1.id, h.t1.id], patch: { accountId: h.acct2.id } });
  assert.equal(clash.status, 400, clash.text);
  assert.equal(clash.json.error.code, 'invalid_toAccountId');
  const e1 = await h.get(h.e1.id);
  assert.equal(e1.accountId, h.account.id, 'e1 的改动被回滚');
  assert.equal(e1.seq, h.e1.seq);

  const missing = await h.bulk({ ids: [h.e1.id, 'no-such-id'], patch: { categoryId: h.catB.id } });
  assert.equal(missing.status, 404, missing.text);
  assert.equal(missing.json.error.code, 'not_found');
  assert.equal((await h.get(h.e1.id)).categoryId, h.catA.id);

  await h.a.del(`/transactions/${h.e2.id}`, h.auth);
  const gone = await h.bulk({ ids: [h.e1.id, h.e2.id], delete: true });
  assert.equal(gone.status, 404, '已删除的也算不存在');
  assert.equal((await h.get(h.e1.id)).deletedAt, null);

  const badRef = await h.bulk({ ids: [h.e1.id], patch: { categoryId: 'nope' } });
  assert.equal(badRef.status, 400);
  assert.equal(badRef.json.error.code, 'invalid_categoryId', '引用校验同 PATCH');
});

test('bulk 参数校验', async (t) => {
  const h = await ledger(t);
  const ids = [h.e1.id];
  const cases = [
    [{ patch: { categoryId: h.catB.id } }, 'invalid_ids'],
    [{ ids: [], patch: { categoryId: h.catB.id } }, 'invalid_ids'],
    [{ ids: [1], delete: true }, 'invalid_ids'],
    [{ ids: Array.from({ length: 501 }, (_, i) => `id-${i}`), delete: true }, 'invalid_ids'],
    [{ ids }, 'invalid_bulk'],
    [{ ids, patch: { categoryId: h.catB.id }, delete: true }, 'invalid_bulk'],
    [{ ids, patch: {} }, 'invalid_bulk'],
    [{ ids, patch: 'x' }, 'invalid_bulk'],
    [{ ids, patch: { amountCents: 1 } }, 'invalid_bulk'],
    [{ ids, delete: 'yes' }, 'invalid_bulk'],
    [{ ids, patch: { status: 'void' } }, 'invalid_status'],
  ];
  for (const [body, code] of cases) {
    const r = await h.bulk(body);
    assert.equal(r.status, 400, `${JSON.stringify(body).slice(0, 80)} → ${r.text}`);
    assert.equal(r.json.error.code, code, JSON.stringify(body).slice(0, 80));
  }
  assert.equal((await h.a.post('/transactions/bulk', { ids, delete: true })).status, 401);
  assert.equal((await h.get(h.e1.id)).deletedAt, null, '失败的请求什么都没动');
});

test('bulk 确认与删除：软删出现在 /changes，活动日志各记一条', async (t) => {
  const h = await ledger(t);
  const p1 = (await h.tx({ type: 'expense', amountCents: 1, status: 'pending' })).json.transaction;
  const p2 = (await h.tx({ type: 'expense', amountCents: 2, status: 'pending' })).json.transaction;

  const ok = await h.bulk({ ids: [p1.id, p2.id], patch: { status: 'confirmed' } });
  assert.deepEqual(ok.json, { updated: 2 });
  assert.equal((await h.get(p1.id)).status, 'confirmed');

  const seq = (await h.get(p2.id)).seq;
  const del = await h.bulk({ ids: [h.e1.id, h.e2.id], delete: true });
  assert.equal(del.status, 200, del.text);
  assert.deepEqual(del.json, { deleted: 2 });
  assert.equal((await h.a.get(`/transactions/${h.e1.id}`, h.auth)).status, 404);
  const left = (await h.a.get('/transactions', h.auth)).json.items.map((x) => x.id);
  assert.ok(!left.includes(h.e1.id) && !left.includes(h.e2.id));
  const tomb = (await h.a.get(`/changes?since=${seq}`, h.auth)).json.transactions;
  assert.deepEqual(tomb.map((x) => x.id).sort(), [h.e1.id, h.e2.id].sort());
  assert.ok(tomb.every((x) => x.deletedAt));

  const db = new DatabaseSync(path.join(h.srv.dataDir, 'famledger.db'), { readOnly: true });
  t.after(() => db.close());
  const actions = db.prepare("SELECT action, member_id FROM activity WHERE action LIKE 'bulk_%' ORDER BY id").all();
  assert.deepEqual(actions.map((a) => a.action), ['bulk_update', 'bulk_delete']);
  assert.ok(actions.every((a) => a.member_id === h.member.id));
});
