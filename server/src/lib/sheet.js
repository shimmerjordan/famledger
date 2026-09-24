'use strict';

// 导入用的表格读取（CSV / XLSX → 字符串二维数组）。零依赖：XLSX 只是 ZIP 包着几份 XML，
// 导入只要值，样式和公式都不必懂。输入是用户上传的任意字节，所以任何畸形都必须变成
// 400 unsupported_file，而不是 500，更不能让一个 zip 炸弹吃光内存。

const path = require('node:path');
const zlib = require('node:zlib');

const { HttpError } = require('./router');

const MAX_UNZIPPED = 50 * 1024 * 1024;
// 账单只有十来列；列号上限挡住 `r="XFD1"` 这种一格撑出上万个空串的放大攻击。
const MAX_COLS = 256;
const MAX_ZIP_ENTRIES = 10000;
// 空单元格不落进结果，但每个仍要扫一遍；几 KB 的 zip 就能解出上千万个 `<c/>` 卡住事件循环。
const MAX_CELLS = 1_000_000;

function unsupported(message) {
  return new HttpError(400, 'unsupported_file', message);
}

const broken = () => unsupported('xlsx 文件不完整或已损坏');

/** 行的上限按非空行数算：Excel 给整片区域刷过格式时会写出成千上万行空行，它们不该占名额。 */
class Rows {
  constructor(maxRows) {
    this.list = [];
    this.max = maxRows;
    this.truncated = false;
  }

  /** @returns {boolean} false 表示已经装满，调用方应停止解析 */
  add(row) {
    if (!row.some((c) => c !== '')) return true;
    if (this.list.length >= this.max) {
      this.truncated = true;
      return false;
    }
    this.list.push(row);
    return true;
  }
}

// ── CSV ──────────────────────────────────────────────────────────────────

/**
 * 支付宝导出是 GBK，微信和 Excel「CSV UTF-8」带 BOM，Excel「Unicode 文本」是 UTF-16。
 * GBK 字节几乎不可能恰好是合法 UTF-8，所以严格 UTF-8 失败就当 GBK（gb18030 是它的超集）。
 */
function decodeText(buf) {
  if (buf[0] === 0xef && buf[1] === 0xbb && buf[2] === 0xbf) return new TextDecoder('utf-8').decode(buf.subarray(3));
  if (buf[0] === 0xff && buf[1] === 0xfe) return new TextDecoder('utf-16le').decode(buf.subarray(2));
  if (buf[0] === 0xfe && buf[1] === 0xff) return new TextDecoder('utf-16be').decode(buf.subarray(2));
  try {
    return new TextDecoder('utf-8', { fatal: true }).decode(buf);
  } catch {
    return new TextDecoder('gbk').decode(buf);
  }
}

/**
 * 按「单行里最多出现几次」比，而不是按总数：支付宝每个订单号后面都跟一个制表符，
 * 总数上制表符不少，但一行里逗号永远更多。
 */
function detectSeparator(text) {
  let comma = 0;
  let tab = 0;
  for (const line of text.slice(0, 65536).split(/\r\n|\n|\r/, 60)) {
    comma = Math.max(comma, line.split(',').length - 1);
    tab = Math.max(tab, line.split('\t').length - 1);
  }
  return tab > comma ? '\t' : ',';
}

/** RFC 4180。引号没闭合时宽松地吞到文件尾：认不出表头自然会 400，解析器本身不该抛。 */
function parseCsv(text, sep, rows) {
  const n = text.length;
  const stop = (c) => c === sep || c === '\n' || c === '\r';
  let row = [];
  let i = 0;
  for (;;) {
    let value;
    if (text[i] === '"') {
      let k = i + 1;
      value = '';
      for (;;) {
        const q = text.indexOf('"', k);
        if (q === -1) {
          value += text.slice(k);
          k = n;
          break;
        }
        value += text.slice(k, q);
        if (text[q + 1] === '"') {
          value += '"';
          k = q + 2;
          continue;
        }
        k = q + 1;
        break;
      }
      // 闭合引号之后、分隔符之前的残渣（支付宝的尾随制表符）并进字段，随后被 trim 掉。
      let e = k;
      while (e < n && !stop(text[e])) e++;
      value += text.slice(k, e);
      i = e;
    } else {
      let e = i;
      while (e < n && !stop(text[e])) e++;
      value = text.slice(i, e);
      i = e;
    }
    if (row.length < MAX_COLS) row.push(value.trim());
    if (i >= n) {
      rows.add(row);
      break;
    }
    if (text[i] === sep) {
      i++;
      continue;
    }
    i += text[i] === '\r' && text[i + 1] === '\n' ? 2 : 1;
    if (!rows.add(row)) break;
    row = [];
    if (i >= n) break;
  }
}

function readCsv(buf, rows) {
  const text = decodeText(buf);
  if (text.includes('\u0000')) throw unsupported('这不是表格文件：支持 CSV 和 xlsx');
  parseCsv(text, detectSeparator(text), rows);
}

// ── ZIP ──────────────────────────────────────────────────────────────────

function readZipDirectory(buf) {
  const min = Math.max(0, buf.length - 22 - 65535);
  let eocd = -1;
  for (let p = buf.length - 22; p >= min; p--) {
    if (buf.readUInt32LE(p) === 0x06054b50) {
      eocd = p;
      break;
    }
  }
  if (eocd < 0) throw unsupported('xlsx 文件不完整或已损坏');
  const count = buf.readUInt16LE(eocd + 10);
  const cdSize = buf.readUInt32LE(eocd + 12);
  const cdOffset = buf.readUInt32LE(eocd + 16);
  if (count === 0xffff || cdOffset === 0xffffffff) throw unsupported('不支持 ZIP64 格式的文件');
  if (cdOffset + cdSize > buf.length || count > MAX_ZIP_ENTRIES) throw unsupported('xlsx 文件不完整或已损坏');

  const entries = new Map();
  let p = cdOffset;
  for (let i = 0; i < count; i++) {
    if (p + 46 > cdOffset + cdSize || buf.readUInt32LE(p) !== 0x02014b50) throw unsupported('xlsx 文件不完整或已损坏');
    const nameLen = buf.readUInt16LE(p + 28);
    const end = p + 46 + nameLen;
    if (end > buf.length) throw unsupported('xlsx 文件不完整或已损坏');
    entries.set(buf.toString('utf8', p + 46, end), {
      flags: buf.readUInt16LE(p + 8),
      method: buf.readUInt16LE(p + 10),
      compSize: buf.readUInt32LE(p + 20),
      offset: buf.readUInt32LE(p + 42),
    });
    p = end + buf.readUInt16LE(p + 30) + buf.readUInt16LE(p + 32);
  }
  return entries;
}

/** `budget.left` 是整包剩余的解压额度：中央目录里声明的大小可以撒谎，额度不会。 */
function inflateEntry(buf, entry, budget) {
  if (entry.flags & 1) throw unsupported('文件加了密码，请先解密再导入');
  const off = entry.offset;
  if (off + 30 > buf.length || buf.readUInt32LE(off) !== 0x04034b50) throw unsupported('xlsx 文件不完整或已损坏');
  const start = off + 30 + buf.readUInt16LE(off + 26) + buf.readUInt16LE(off + 28);
  const end = start + entry.compSize;
  if (end > buf.length) throw unsupported('xlsx 文件不完整或已损坏');
  const data = buf.subarray(start, end);
  if (budget.left <= 0) throw unsupported('文件解压后超过 50MB');

  let out;
  if (entry.method === 0) {
    out = data;
  } else if (entry.method === 8) {
    try {
      out = zlib.inflateRawSync(data, { maxOutputLength: budget.left });
    } catch (e) {
      if (e && e.code === 'ERR_BUFFER_TOO_LARGE') throw unsupported('文件解压后超过 50MB');
      throw unsupported('xlsx 文件不完整或已损坏');
    }
  } else {
    throw unsupported('xlsx 用了不支持的压缩方式');
  }
  if (out.length > budget.left) throw unsupported('文件解压后超过 50MB');
  budget.left -= out.length;
  return out.toString('utf8');
}

// ── XLSX ─────────────────────────────────────────────────────────────────

const ENTITIES = { amp: '&', lt: '<', gt: '>', quot: '"', apos: "'" };

function decodeXml(s) {
  return s
    .replace(/&(#x[0-9a-fA-F]+|#\d+|amp|lt|gt|quot|apos);/g, (m, e) => {
      if (e[0] !== '#') return ENTITIES[e];
      const cp = e[1] === 'x' ? parseInt(e.slice(2), 16) : parseInt(e.slice(1), 10);
      return cp > 0 && cp <= 0x10ffff ? String.fromCodePoint(cp) : '';
    })
    // Excel 把控制字符写成 `_x000D_` 这种转义，不还原的话备注里会冒出这串字面量。
    .replace(/_x([0-9a-fA-F]{4})_/g, (m, h) => String.fromCharCode(parseInt(h, 16)));
}

/** 有的生成器给每个标签带命名空间前缀（`<x:c>`），统一剥掉，后面只认裸标签。 */
const stripPrefixes = (xml) => xml.replace(/<(\/?)[A-Za-z_][\w.-]*:/g, '<$1');

function attr(attrs, name) {
  const m = new RegExp(`(?:^|\\s)${name}\\s*=\\s*(?:"([^"]*)"|'([^']*)')`).exec(attrs);
  return m ? decodeXml(m[1] ?? m[2]) : null;
}

/** `<row` 不能把 `<rowBreaks` 也算进来。 */
const endsName = (ch) => ch === '>' || ch === '/' || ch === ' ' || ch === '\t' || ch === '\n' || ch === '\r';

/**
 * 不用 `<row[^>]*>([\s\S]*?)</row>` 这类正则：标签没闭合时它会从每个起点扫到文件尾，几 KB 的上传就能
 * 把单进程卡上几分钟。这里每个字符只看常数遍，缺闭合直接判损坏。同名元素不嵌套；inner 为 null 表示自闭合；
 * withBody 为 false 只读开标签，给 `<sheet>`、`<Relationship>` 这类空元素用。
 * @returns {Generator<{attrs: string, inner: string|null, start: number, end: number}>}
 */
function* elements(xml, tag, withBody = true) {
  const open = `<${tag}`;
  const close = `</${tag}>`;
  let pos = 0;
  for (;;) {
    const start = xml.indexOf(open, pos);
    if (start < 0) return;
    const nameEnd = start + open.length;
    if (nameEnd < xml.length && !endsName(xml[nameEnd])) {
      pos = nameEnd;
      continue;
    }
    const gt = xml.indexOf('>', nameEnd);
    if (gt < 0) throw broken();
    const selfClosing = xml[gt - 1] === '/';
    const attrs = xml.slice(nameEnd, selfClosing ? gt - 1 : gt);
    if (selfClosing || !withBody) {
      pos = gt + 1;
      yield { attrs, inner: null, start, end: pos };
      continue;
    }
    const at = xml.indexOf(close, gt + 1);
    if (at < 0) throw broken();
    pos = at + close.length;
    yield { attrs, inner: xml.slice(gt + 1, at), start, end: pos };
  }
}

function firstElement(xml, tag, withBody) {
  for (const el of elements(xml, tag, withBody)) return el;
  return null;
}

/** 富文本单元格由多段 `<r><t>` 拼成；`<rPh>` 是注音，里面也有 `<t>`，读进来会把原文弄脏。 */
function richText(inner) {
  let text = inner;
  if (inner.includes('<rPh')) {
    text = '';
    let from = 0;
    for (const ph of elements(inner, 'rPh')) {
      text += inner.slice(from, ph.start);
      from = ph.end;
    }
    text += inner.slice(from);
  }
  let s = '';
  for (const t of elements(text, 't')) if (t.inner !== null) s += t.inner;
  return decodeXml(s);
}

function parseSharedStrings(xml) {
  const out = [];
  for (const si of elements(stripPrefixes(xml), 'si')) {
    // 表里的格子总数有上限，比它还多的共享字符串不可能都被引用到，只会白占内存。
    if (out.length >= MAX_CELLS) throw unsupported('表格太大，请拆成几个文件再导入');
    out.push(si.inner === null ? '' : richText(si.inner));
  }
  return out;
}

function columnIndex(ref) {
  const m = /^([A-Z]+)/.exec(ref || '');
  if (!m) return -1;
  let n = 0;
  for (const ch of m[1]) {
    n = n * 26 + (ch.charCodeAt(0) - 64);
    if (n > MAX_COLS) return MAX_COLS;
  }
  return n - 1;
}

function cellValue(attrs, inner, shared) {
  if (inner === null) return '';
  const type = attr(attrs, 't');
  if (type === 'inlineStr') {
    const is = firstElement(inner, 'is');
    return is && is.inner !== null ? richText(is.inner) : '';
  }
  const v = firstElement(inner, 'v');
  const raw = v && v.inner !== null ? decodeXml(v.inner) : '';
  if (type === 's') return raw === '' ? '' : (shared[Number(raw)] ?? '');
  if (type === 'b') return raw === '1' ? 'TRUE' : raw === '0' ? 'FALSE' : '';
  if (type === 'e') return '';
  return raw;
}

function parseSheet(xml, shared, rows) {
  const data = firstElement(stripPrefixes(xml), 'sheetData');
  if (!data || data.inner === null) return;
  let cells = 0;
  for (const rowEl of elements(data.inner, 'row')) {
    const row = [];
    if (rowEl.inner !== null) {
      // 没写 r 的格子按出现顺序排；空格子不落进 row，所以下一列得单独记。
      let next = 0;
      for (const c of elements(rowEl.inner, 'c')) {
        if (++cells > MAX_CELLS) throw unsupported('表格太大，请拆成几个文件再导入');
        let col = columnIndex(attr(c.attrs, 'r'));
        if (col < 0) col = next;
        next = col + 1;
        if (col >= MAX_COLS) continue;
        // 空格子不补位：`<c r="IU"/>` 一格就能撑出 255 个空串，几十字节放大成几 KB。
        const value = cellValue(c.attrs, c.inner, shared).trim();
        if (value === '') continue;
        while (row.length < col) row.push('');
        row[col] = value;
      }
    }
    if (!rows.add(row)) return;
  }
}

/** 用户眼里的第一张表是 workbook.xml 里排第一的那张，文件未必叫 sheet1.xml。 */
function firstSheetPath(entries, read) {
  const wb = entries.has('xl/workbook.xml') ? stripPrefixes(read('xl/workbook.xml')) : '';
  const sheet = firstElement(wb, 'sheet', false);
  const rid = sheet ? attr(sheet.attrs, 'r:id') : null;
  if (rid && entries.has('xl/_rels/workbook.xml.rels')) {
    const rels = stripPrefixes(read('xl/_rels/workbook.xml.rels'));
    for (const rel of elements(rels, 'Relationship', false)) {
      if (attr(rel.attrs, 'Id') !== rid) continue;
      const target = attr(rel.attrs, 'Target') || '';
      const p = target.startsWith('/') ? target.slice(1) : path.posix.normalize(`xl/${target}`);
      if (entries.has(p)) return { sheet: p, workbook: wb };
    }
  }
  const guess = [...entries.keys()].filter((k) => /^xl\/worksheets\/[^/]+\.xml$/.test(k)).sort()[0];
  return { sheet: guess || null, workbook: wb };
}

/** @returns {boolean} 是否 1904 日期系统 */
function readXlsx(buf, rows) {
  const entries = readZipDirectory(buf);
  if (!entries.has('xl/workbook.xml')) {
    if ([...entries.keys()].some((k) => /\.csv$/i.test(k))) {
      throw unsupported('这是一个压缩包：请先解压，再导入里面的 CSV 文件');
    }
    throw unsupported('不是有效的 xlsx 文件');
  }
  const budget = { left: MAX_UNZIPPED };
  const read = (name) => inflateEntry(buf, entries.get(name), budget);

  const { sheet, workbook } = firstSheetPath(entries, read);
  if (!sheet) throw unsupported('xlsx 里没有工作表');
  const pr = firstElement(workbook, 'workbookPr', false);
  const d1904 = pr ? attr(pr.attrs, 'date1904') : null;
  const shared = entries.has('xl/sharedStrings.xml') ? parseSharedStrings(read('xl/sharedStrings.xml')) : [];
  parseSheet(read(sheet), shared, rows);
  return d1904 === '1' || d1904 === 'true';
}

// ── 入口 ─────────────────────────────────────────────────────────────────

/**
 * 全空的行不出现在结果里（表头前后的空行对识别和导入都没有意义）。
 * @param {Buffer} buffer 上传的原始字节
 * @param {string} [filename] 只用来给出更好懂的报错，格式按魔数判断
 * @param {{maxRows?: number}} [opts] 非空行读满 maxRows 就停，免得巨型文件先整个物化进内存再被拒
 * @returns {{rows: string[][], date1904: boolean, truncated: boolean}} truncated：后面还有没读的行
 */
function readTable(buffer, filename = '', { maxRows = Infinity } = {}) {
  if (!Buffer.isBuffer(buffer) || buffer.length === 0) throw unsupported('文件是空的');
  const rows = new Rows(maxRows);
  let date1904 = false;
  try {
    if (buffer.length >= 4 && buffer.readUInt32LE(0) === 0x04034b50) {
      date1904 = readXlsx(buffer, rows);
    } else if (buffer.length >= 4 && buffer.readUInt32LE(0) === 0xe011cfd0) {
      throw unsupported('暂不支持旧版 .xls：请在 Excel 里另存为 .xlsx 或 CSV 再导入');
    } else if (/\.(xlsx|zip)$/i.test(filename)) {
      throw unsupported('xlsx 文件不完整或已损坏');
    } else {
      readCsv(buffer, rows);
    }
  } catch (e) {
    if (e instanceof HttpError) throw e;
    throw unsupported('文件读不出来：支持 CSV 和 xlsx');
  }
  return { rows: rows.list, date1904, truncated: rows.truncated };
}

/**
 * Excel 日期序列号 → `YYYY-MM-DD HH:MM:SS`（墙上时间，不带时区）；越界返回 null。
 * 1900 系统沿用了 Lotus 的错把 1900 年当闰年，所以 60 以前要补回一天。
 */
function excelSerialToDate(serial, date1904 = false) {
  const n = typeof serial === 'number' ? serial : Number(String(serial ?? '').trim());
  if (!Number.isFinite(n) || n < (date1904 ? 0 : 1) || n > 2958465) return null;
  const epoch = date1904 ? Date.UTC(1904, 0, 1) : Date.UTC(1899, 11, 30);
  const days = !date1904 && n < 60 ? n + 1 : n;
  const d = new Date(epoch + Math.round(days * 86400) * 1000);
  const p = (x) => String(x).padStart(2, '0');
  return (
    `${d.getUTCFullYear()}-${p(d.getUTCMonth() + 1)}-${p(d.getUTCDate())}` +
    ` ${p(d.getUTCHours())}:${p(d.getUTCMinutes())}:${p(d.getUTCSeconds())}`
  );
}

module.exports = { readTable, excelSerialToDate };
