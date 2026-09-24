'use strict';

// 表格导入的预览：把支付宝/微信账单或通用模板读成一行行候选流水，附上跳过原因、
// 查重提示和猜出的类别。这里不写流水 —— 用户在预览页改完再走 POST /transactions/batch，
// 同一个文件导两次不重复入账，全靠这里算出的稳定 clientId。唯一可能落库的是新家庭第一次
// 用到模型时懒建的种子模型，与 GET /model 同一条路，不推高 model_version。

const crypto = require('node:crypto');

const { HttpError, sendJson } = require('../lib/router');
const { readTable, excelSerialToDate } = require('../lib/sheet');
const nb = require('../lib/nb');
const v = require('../lib/validate');

// base64 膨胀 4/3，8MB 请求体大约装得下 6MB 的原文件。
const MAX_BODY = 8 * 1024 * 1024;
const MAX_ROWS = 5000;
const HEADER_SCAN = 40;
// 表头前的说明、账单末尾的汇总也占行，但非空行多到 MAX_ROWS 的两倍就不会是正常账单了，不必再往下读。
const READ_ROWS = MAX_ROWS * 2;
const MAX_AMOUNT = 1e14;
// 与 transactions.js 的列宽一致，超长的在这里截掉，免得整批提交时逐条 400。
const MERCHANT_MAX = 120;
const NOTE_MAX = 1000;
// 支付宝/微信账单里的时间都是北京时间，模板也是国内家庭自己填的。
const OFFSET = '+08:00';
// 只把 1954~2119 年范围内的数字当日期序列号：更小的更像笔数或金额。
const SERIAL_MIN = 20000;
const SERIAL_MAX = 80000;
// 与 App 端 NaiveBayes.isReliable 同一条线：薄模型的后验没有意义，宁可不猜。
const MIN_MODEL_CLASSES = 2;
const MIN_MODEL_DOCS = 3;
// 后验低于这条线就不填类别，让这行留在预览页的「未分类」里：那里只认 categoryId 为空，
// 填了乱猜的类别，用户不逐行点开就会原样入库。种子模型下一个字都不认识时第一名只靠先验，
// 约 0.08，收入行还要被支出类别分走大半；实测 0.2 以下的猜测大多是错的（便利店→医疗）。
// 不用「至少认识一个字」来判：种子词表里单字太多，「某某小馆」这类照样命中，拦不住。
const MIN_GUESS = 0.2;

// 支付宝账单自带的「交易分类」→ 默认类别名。模型猜不出或后验不到一半时拿它兜底：这是支付宝
// 按商户类目标的，比没把握的后验可靠，所以给 0.6；模型有把握时仍听模型的，它学过这家人的改正。
// 只收一一对得上的：美容美发、运动户外、生活服务、充值缴费这类横跨好几个类别的不收，
// 投资理财、转账红包、信用借还、退款本就不是消费，「其他」等于支付宝也没认出来。
// 目标只能是 seed.js 里的默认类别名；家里改了名、删了、归档了或收支方向不对就不给。
// 用 Map：键来自上传的文件，普通对象上「__proto__」「constructor」会读出原型上的东西。
const ALIPAY_CATEGORY = new Map([
  ['餐饮美食', '餐饮'],
  ['交通出行', '交通'],
  ['爱车养车', '交通'],
  ['日用百货', '购物'],
  ['服饰装扮', '购物'],
  ['数码电器', '购物'],
  ['住房物业', '居家'],
  ['家居家装', '居家'],
  ['医疗健康', '医疗'],
  ['教育培训', '教育'],
  ['母婴亲子', '育儿'],
  ['宠物', '宠物'],
  ['文化休闲', '娱乐'],
  ['酒店旅游', '旅行'],
  ['保险', '保险'],
  ['公益捐赠', '其他'],
]);
const MAPPED_BELOW = 0.5;
const MAPPED_CONFIDENCE = 0.6;

const SKIP = {
  neutral: { code: 'neutral', message: '不计收支（转账、充值、理财等），不记账' },
  closed: { code: 'closed', message: '交易已关闭，钱没有付出去' },
  refund: { code: 'refund', message: '有退款，跳过以免记错' },
};
const invalid = (message) => ({ code: 'invalid', message });
const KIND_LABEL = { expense: '支出', income: '收入' };

// 列名给多个别名：用户用 Excel 打开再另存，全角/半角括号常常被改掉。
const FORMATS = [
  {
    source: 'alipay',
    label: '支付宝账单',
    channel: 'alipay',
    accountKind: 'alipay',
    categoryMap: ALIPAY_CATEGORY,
    keys: ['交易时间', '收/支', '交易状态'],
    cols: {
      time: ['交易时间'], rawCategory: ['交易分类'], merchant: ['交易对方'], note: ['商品说明'], remark: ['备注'],
      dir: ['收/支'], amount: ['金额', '金额（元）', '金额(元)'], method: ['收/付款方式'], status: ['交易状态'],
      order: ['交易订单号'],
    },
    skip(dir, status) {
      if (dir !== '支出' && dir !== '收入') return SKIP.neutral;
      if (status.includes('关闭')) return SKIP.closed;
      if (status.includes('退款')) return SKIP.refund;
      return null;
    },
  },
  {
    source: 'wechat',
    label: '微信账单',
    channel: 'wechat',
    accountKind: 'wechat',
    keys: ['交易时间', '收/支', '当前状态'],
    cols: {
      time: ['交易时间'], rawCategory: ['交易类型'], merchant: ['交易对方'], note: ['商品'], remark: ['备注'],
      dir: ['收/支'], amount: ['金额(元)', '金额（元）', '金额'], method: ['支付方式'], status: ['当前状态'],
      order: ['交易单号'],
    },
    skip(dir, status) {
      if (dir !== '支出' && dir !== '收入') return SKIP.neutral;
      if (status.includes('退款') || status.includes('已退还')) return SKIP.refund;
      return null;
    },
  },
  {
    source: 'template',
    label: '通用模板',
    keys: ['日期', '金额'],
    cols: {
      date: ['日期'], dir: ['收支'], amount: ['金额'], category: ['类别'], fund: ['基金'], account: ['账户'], note: ['备注'],
    },
  },
];

// BOM 让 Excel 按 UTF-8 打开；CRLF 是 Excel 自己写 CSV 的换行。
const TEMPLATE_CSV =
  '﻿' +
  ['日期,收支,金额,类别,基金,账户,备注', '2026-09-12 12:30,支出,35.00,餐饮,,现金,午饭', '2026-09-10,收入,8000,工资,,,九月工资', ''].join('\r\n');

const WHEN_RE = /^(\d{4})[-/.年](\d{1,2})[-/.月](\d{1,2})日?(?:[ T]+(\d{1,2}):(\d{1,2})(?::(\d{1,2})(?:\.\d+)?)?)?$/;

/**
 * 表格里的日期 → 带 +08:00 的本地时间。只有日期时落在中午：离两头的零点都远，
 * 哪个客户端按什么时区显示都还是同一天。
 * @returns {{iso: string, hour: number, weekday: number}|null}
 */
function parseWhen(raw, date1904) {
  let s = String(raw ?? '').trim();
  if (/^\d+(\.\d+)?$/.test(s) && !/^\d{8}$/.test(s)) {
    const n = Number(s);
    if (n < SERIAL_MIN || n > SERIAL_MAX) return null;
    s = excelSerialToDate(n, date1904);
    if (Number.isInteger(n)) s = s.slice(0, 10);
  }
  const m = WHEN_RE.exec(s) || /^(\d{4})(\d{2})(\d{2})$/.exec(s);
  if (!m) return null;
  const [y, mo, d] = [m[1], m[2], m[3]].map(Number);
  const [h, mi, se] = m[4] === undefined ? [12, 0, 0] : [Number(m[4]), Number(m[5]), Number(m[6] ?? 0)];
  const day = new Date(Date.UTC(y, mo - 1, d));
  if (y < 1900 || y > 2200 || day.getUTCMonth() !== mo - 1 || day.getUTCDate() !== d) return null;
  if (h > 23 || mi > 59 || se > 59) return null;
  const p = (x) => String(x).padStart(2, '0');
  return {
    iso: `${y}-${p(mo)}-${p(d)}T${p(h)}:${p(mi)}:${p(se)}${OFFSET}`,
    hour: h,
    // App 端特征用 DateTime.weekday（1=周一 … 7=周日），这里要对得上。
    weekday: day.getUTCDay() || 7,
  };
}

/** `¥1,234.50` → 123450。两位小数以内按字符串算，免得 4.35 × 100 这类浮点误差。 */
function parseCents(raw) {
  const s = String(raw ?? '').replace(/[¥￥,，\s]|元/g, '');
  const m = /^([+-]?)(\d*)(?:\.(\d{0,2}))?$/.exec(s);
  let cents;
  if (m && (m[2] || m[3])) {
    cents = Number(m[2] || '0') * 100 + Number((m[3] || '').padEnd(2, '0'));
    if (m[1] === '-') cents = -cents;
  } else if (/^[+-]?(\d+\.?\d*|\.\d+)(e[+-]?\d+)?$/i.test(s)) {
    // xlsx 里的数字是二进制浮点的十进制展开（35.499999999999），只能四舍五入。
    cents = Math.round(Number(s) * 100);
  } else {
    return null;
  }
  return Number.isSafeInteger(cents) && Math.abs(cents) <= MAX_AMOUNT ? cents : null;
}

/** 截到列宽以内，且不把一个代理对从中间劈开。 */
function clip(s, max) {
  if (s.length <= max) return s;
  const cut = s.slice(0, max);
  return /[\ud800-\udbff]$/.test(cut) ? cut.slice(0, -1) : cut;
}

function findHeader(rows) {
  for (let i = 0; i < Math.min(rows.length, HEADER_SCAN); i++) {
    const cells = new Set(rows[i]);
    const format = FORMATS.find((f) => f.keys.every((k) => cells.has(k)));
    if (format) return { format, index: i };
  }
  return null;
}

function columnMap(header, cols) {
  const out = {};
  for (const [name, aliases] of Object.entries(cols)) out[name] = header.findIndex((h) => aliases.includes(h));
  return out;
}

const cell = (row, idx) => (idx >= 0 && idx < row.length ? row[idx] : '');
// 微信账单用「/」表示这一格没有内容。
const blank = (s) => (s === '/' ? '' : s);

function decodeData(raw) {
  if (typeof raw !== 'string' || raw === '') v.bad('data', 'data 必须是文件内容的 base64');
  const s = raw.replace(/^data:[^,]*,/, '').replace(/\s+/g, '');
  if (!/^[A-Za-z0-9+/_-]*={0,2}$/.test(s)) v.bad('data', 'data 不是合法的 base64');
  return Buffer.from(s, 'base64');
}

function hintList(hints, key) {
  const list = hints && Array.isArray(hints[key]) ? hints[key] : [];
  return list.map((x) => String(x).trim()).filter(Boolean);
}

module.exports = (ctx) => {
  const { db } = ctx;

  /** 可信的模型连同它的词表一起给出：一次预览几千行都用同一个模型，词表只建一遍。 */
  function reliable(model) {
    if (Object.keys(model.classes).length < MIN_MODEL_CLASSES || model.totalDocs < MIN_MODEL_DOCS) return null;
    const vocab = nb.vocabulary(model);
    return (tokens) => nb.predict(model, tokens, vocab);
  }

  /** 库里的类别/基金/账户，只认没归档的：导入的新流水不该落进已经收起来的地方。 */
  function lookups() {
    const live = (table, cols) =>
      db.all(`SELECT ${cols} FROM ${table} WHERE archived = 0 AND deleted_at IS NULL ORDER BY sort_order, created_at`);
    const categories = live('categories', 'id, name, kind');
    const funds = live('funds', 'id, name');
    const accounts = live('accounts', 'id, name, kind, match_hints').map((a) => {
      let hints = {};
      try {
        hints = JSON.parse(a.match_hints || '{}');
      } catch {
        /* 坏掉的 matchHints 只是不参与匹配 */
      }
      return { ...a, tails: hintList(hints, 'cardTails'), keywords: hintList(hints, 'keywords') };
    });
    return { categories, funds, accounts };
  }

  /** 卡尾号比关键词具体，先比；都没命中就落到这个来源对应种类的第一个账户。 */
  function guessAccount(accounts, kind, method) {
    if (method) {
      const byTail = accounts.find((a) => a.tails.some((t) => method.includes(t)));
      if (byTail) return byTail.id;
      const byWord = accounts.find((a) => a.keywords.some((k) => method.includes(k)));
      if (byWord) return byWord.id;
    }
    return accounts.find((a) => a.kind === kind)?.id ?? null;
  }

  function billRow(format, col, row, when) {
    const dir = cell(row, col.dir);
    const type = dir === '收入' ? 'income' : 'expense';
    const amountCents = parseCents(cell(row, col.amount));
    let skip = format.skip(dir, cell(row, col.status));
    if (!skip && amountCents === null) skip = invalid('金额看不懂');
    else if (!skip && amountCents <= 0) skip = invalid('金额必须大于 0');
    const note = [blank(cell(row, col.note)), blank(cell(row, col.remark))].filter(Boolean).join(' ');
    return {
      order: blank(cell(row, col.order)).replace(/\s+/g, ''),
      type,
      amountCents,
      when,
      merchant: blank(cell(row, col.merchant)),
      note,
      rawCategory: blank(cell(row, col.rawCategory)) || null,
      method: blank(cell(row, col.method)),
      skip,
    };
  }

  function templateRow(col, row, when, refs) {
    const dir = cell(row, col.dir);
    let type = dir === '收入' ? 'income' : 'expense';
    let amountCents = parseCents(cell(row, col.amount));
    if (amountCents !== null && amountCents < 0) {
      type = 'expense';
      amountCents = -amountCents;
    }
    let skip = null;
    if (!when) skip = invalid('日期看不懂，写成 2026-09-12 这样');
    else if (amountCents === null) skip = invalid('金额看不懂');
    else if (amountCents <= 0) skip = invalid('金额必须大于 0');

    const hints = [];
    const pick = (name, label, rows, fits = () => true) => {
      if (!name) return null;
      const same = rows.filter((r) => r.name === name);
      const hit = same.find(fits);
      if (hit) return hit.id;
      // 同名的只有反方向的类别时不能凑合挂上：批量入库不查类别方向，支出会落进收入类别里。
      const other = same[0];
      hints.push(other ? `${label}「${name}」是${KIND_LABEL[other.kind]}类别，这笔是${KIND_LABEL[type]}` : `${label}「${name}」不存在`);
      return null;
    };
    const categoryName = cell(row, col.category);
    // 「其他」支出、收入各有一个：按这一行的收支挑同类的那个。
    const categoryId = pick(categoryName, '类别', refs.categories, (c) => c.kind === type);
    const fundId = pick(cell(row, col.fund), '基金', refs.funds);
    const accountId = pick(cell(row, col.account), '账户', refs.accounts);
    return {
      order: '',
      type,
      amountCents,
      when,
      merchant: '',
      note: cell(row, col.note),
      rawCategory: categoryName || null,
      categoryId,
      fundId,
      accountId,
      skip,
      hint: hints.length ? hints.join('；') : null,
    };
  }

  function preview(req, res, reqCtx) {
    const b = v.body(reqCtx.body);
    const filename = v.optStr(b.filename, 'filename', { max: 255 }) || '';
    const { rows, date1904, truncated } = readTable(decodeData(b.data), filename, { maxRows: READ_ROWS });

    const found = findHeader(rows);
    if (!found) throw new HttpError(400, 'unsupported_file', '认不出这个表格：支持支付宝账单、微信账单和通用模板');
    if (truncated) {
      throw new HttpError(400, 'too_many_rows', `一次最多导入 ${MAX_ROWS} 行，这个文件超过 ${READ_ROWS} 行，请拆开再导`);
    }
    const { format, index } = found;
    const col = columnMap(rows[index], format.cols);
    const isBill = format.source !== 'template';

    // 账单前后夹着说明文字和汇总行（「共8笔记录」「已支出:5笔,…」）；交易时间读不出来的
    // 就不是一笔交易。模板是用户自己填的，读不懂的要摆出来让人看见（空行 readTable 已经丢了）。
    const data = [];
    for (const row of rows.slice(index + 1)) {
      const when = parseWhen(cell(row, isBill ? col.time : col.date), date1904);
      if (when || !isBill) data.push({ row, when });
    }
    if (data.length > MAX_ROWS) {
      throw new HttpError(400, 'too_many_rows', `一次最多导入 ${MAX_ROWS} 行，这个文件有 ${data.length} 行，请拆开再导`);
    }

    const refs = lookups();
    const parsed = data.map(({ row, when }) => (isBill ? billRow(format, col, row, when) : templateRow(col, row, when, refs)));

    // 与 GET /model 同一条懒初始化：新家庭还没有哪台设备拉过模型，也照样有种子模型可猜。
    // 在请求时取，见 model.js 挂上它的地方。
    const models = ctx.ensureModel();
    const predictCategory = reliable(models.category);
    const predictFund = reliable(models.fund);
    const categoryById = new Map(refs.categories.map((c) => [c.id, c]));
    const fundIds = new Set(refs.funds.map((f) => f.id));
    // 同名同方向的有几个就取排在最前的那个，与模板按名称挑类别一致。
    const categoryByName = new Map();
    for (const c of refs.categories) {
      const k = `${c.kind}\u0000${c.name}`;
      if (!categoryByName.has(k)) categoryByName.set(k, c.id);
    }

    const occurrences = new Map();
    const items = parsed.map((p, i) => {
      const occurredAt = p.when ? p.when.iso : null;
      const merchant = clip(p.merchant, MERCHANT_MAX);
      const note = clip(p.note, NOTE_MAX);

      const base = p.order
        ? `${format.source}|${p.order}`
        : `${format.source}|${occurredAt}|${p.amountCents}|${merchant}|${note}`;
      const n = (occurrences.get(base) || 0) + 1;
      occurrences.set(base, n);
      // 有订单号时第一次就用「来源|订单号」本身；同号再出现才加序号，免得两行抢一个 clientId。
      const basis = p.order && n === 1 ? base : `${base}|${n}`;
      const clientId = `imp-${crypto.createHash('sha1').update(basis).digest('hex').slice(0, 16)}`;

      const item = {
        row: i + 1,
        clientId,
        type: p.type,
        amountCents: p.amountCents,
        occurredAt,
        merchant,
        note,
        rawCategory: p.rawCategory,
        categoryId: isBill ? null : p.categoryId,
        fundId: isBill ? null : p.fundId,
        accountId: isBill ? guessAccount(refs.accounts, format.accountKind, p.method) : p.accountId,
        confidence: null,
        skip: p.skip,
        exists: !!db.get('SELECT 1 AS ok FROM transactions WHERE client_id = ?', clientId),
        duplicateOf: null,
        hint: isBill ? null : p.hint,
      };

      if (!item.skip) {
        const dup = db.get(
          'SELECT id FROM transactions WHERE deleted_at IS NULL AND type = ? AND amount_cents = ?' +
            ' AND substr(occurred_at, 1, 10) = ? AND (client_id IS NULL OR client_id <> ?)' +
            " AND (? = '' OR merchant = '' OR merchant = ?) ORDER BY occurred_at, id LIMIT 1",
          item.type, item.amountCents, occurredAt.slice(0, 10), clientId, merchant, merchant,
        );
        item.duplicateOf = dup ? dup.id : null;
      }

      if (!item.skip && item.categoryId === null) {
        let guessed = 0; // 不拿四舍五入后的 confidence 比：0.49996 显示成 0.5，也还是没把握
        if (predictCategory || predictFund) {
          // 有商户就只用商户：种子样本是「商户关键词 → 类别」，整句备注里的噪声字会压过商户词。
          const tokens = nb.tokenize(merchant || note, nb.extrasFor({
            merchant,
            direction: item.type,
            channel: format.channel,
            amountCents: item.amountCents,
            hour: p.when.hour,
            weekday: p.when.weekday,
            memberId: reqCtx.member.id,
          }));
          if (predictCategory) {
            // 模型的标签可能是已删、已归档或收支方向不对的类别，挑第一个现在还能用的。
            const hit = predictCategory(tokens).find((x) => categoryById.get(x.label)?.kind === item.type);
            if (hit && hit.p >= MIN_GUESS) {
              item.categoryId = hit.label;
              item.confidence = Math.round(hit.p * 1e4) / 1e4;
              guessed = hit.p;
            }
          }
          if (predictFund && item.fundId === null) {
            const hit = predictFund(tokens).find((x) => fundIds.has(x.label));
            if (hit) item.fundId = hit.label;
          }
        }
        const mappedName = guessed < MAPPED_BELOW && format.categoryMap?.get(p.rawCategory);
        const mapped = mappedName && categoryByName.get(`${item.type}\u0000${mappedName}`);
        if (mapped) {
          item.categoryId = mapped;
          item.confidence = MAPPED_CONFIDENCE;
        }
      }
      return item;
    });

    const skipped = items.filter((x) => x.skip).length;
    sendJson(res, 200, {
      source: format.source,
      sourceLabel: format.label,
      total: items.length,
      importable: items.length - skipped,
      skipped,
      rows: items,
    });
  }

  function template(req, res) {
    const body = Buffer.from(TEMPLATE_CSV, 'utf8');
    res.writeHead(200, {
      'content-type': 'text/csv; charset=utf-8',
      'content-disposition': 'attachment; filename="famledger-template.csv"',
      'content-length': body.length,
    });
    res.end(body);
  }

  return {
    name: 'imports',
    routes: [
      { method: 'POST', pattern: '/import/preview', handler: preview, maxBody: MAX_BODY },
      // 模板里没有任何家庭数据；浏览器直接打开链接下载时带不上 Bearer token。
      { method: 'GET', pattern: '/import/template.csv', handler: template, auth: 'none', maxBody: 0 },
    ],
  };
};
