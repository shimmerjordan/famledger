'use strict';

// 解析模型的导入输出（spec §6「抽取管线」）。约定的形状是单个对象：
//
//   {"records":[{…},{…}], "done":true}
//
// records 扁平排列，末尾的 done:true 是哨兵 —— 截断判定以它为主（国产兼容端和 cc-trans 未必透传结束原因）。
// 容忍：前后的废话和代码块、把哨兵写成 records 里最后一条 {"done":true}、顶层直接是数组。
//
//   parseImportOutput(text) → { ok, records, done, salvaged }
//       ok        解析出了 records（哪怕是空数组）；false = 一条都救不回来（→ ai_bad_output）
//       done      见到了哨兵
//       salvaged  整体 JSON.parse 失败，是状态机逐条救回来的
//   createRecordCounter() → { push(chunk) → 已经完整收到几条 }   流式进度用，跨分片保持状态

const isObject = (x) => x !== null && typeof x === 'object' && !Array.isArray(x);
const isSentinel = (x) => isObject(x) && x.done === true && Object.keys(x).length === 1;

/** 去掉代码块外壳：有 ``` 就取第一个代码块里的内容（没闭合也算，截断时常见）。 */
function unfence(text) {
  const s = String(text ?? '').trim();
  const m = s.match(/```(?:json)?\s*([\s\S]*?)(?:```|$)/i);
  return m ? m[1].trim() : s;
}

function finish(list, doneFlag, salvaged) {
  const records = [];
  let done = doneFlag;
  for (const r of list) {
    if (isSentinel(r)) done = true;
    else if (isObject(r)) records.push(r);
  }
  return { ok: true, records, done, salvaged };
}

/**
 * 状态机逐条抢救：从 records 数组（或顶层数组）开始扫，字符串里的括号不算，每收齐一个完整对象就单独 JSON.parse。
 * 数组正常闭合后再找 "done":true。
 */
function salvage(s) {
  let start = -1;
  const key = s.search(/"records"\s*:\s*\[/);
  if (key >= 0) start = s.indexOf('[', key);
  else if (s.trimStart().startsWith('[')) start = s.indexOf('[');
  if (start < 0) return { ok: false, records: [], done: false, salvaged: true };
  const out = [];
  let depth = 0;
  let inStr = false;
  let esc = false;
  let objStart = -1;
  let closedAt = -1;
  for (let i = start + 1; i < s.length; i++) {
    const c = s[i];
    if (inStr) {
      if (esc) esc = false;
      else if (c === '\\') esc = true;
      else if (c === '"') inStr = false;
      continue;
    }
    if (c === '"') inStr = true;
    else if (c === '{' || c === '[') {
      if (depth === 0 && c === '{') objStart = i;
      depth++;
    } else if (c === '}' || c === ']') {
      if (depth === 0) {
        if (c === ']') closedAt = i;
        break;
      }
      depth--;
      if (depth === 0 && c === '}' && objStart >= 0) {
        try {
          out.push(JSON.parse(s.slice(objStart, i + 1)));
        } catch {
          /* 这一条坏了就跳过，接着救下一条 */
        }
        objStart = -1;
      }
    }
  }
  const done = closedAt >= 0 && /"done"\s*:\s*true/.test(s.slice(closedAt));
  const res = finish(out, done, true);
  res.ok = res.records.length > 0 || (closedAt >= 0 && out.length === 0 && done);
  return res;
}

function parseImportOutput(text) {
  const s = unfence(text);
  const brace = s.indexOf('{');
  const bracket = s.indexOf('[');
  // 顶层直接是数组（没套 {"records":…}）
  if (bracket >= 0 && (brace < 0 || bracket < brace)) {
    try {
      const arr = JSON.parse(s.slice(bracket, s.lastIndexOf(']') + 1));
      if (Array.isArray(arr)) return finish(arr, false, false);
    } catch {
      return salvage(s.slice(bracket));
    }
  }
  if (brace < 0) return { ok: false, records: [], done: false, salvaged: false };
  const end = s.lastIndexOf('}');
  if (end > brace) {
    try {
      const obj = JSON.parse(s.slice(brace, end + 1));
      if (isObject(obj) && Array.isArray(obj.records)) return finish(obj.records, obj.done === true, false);
    } catch {
      /* 落到下面的逐条抢救 */
    }
  }
  return salvage(s.slice(brace));
}

/**
 * 流式进度：数「顶层对象 → 数组 → 对象」这一层闭合了几次，也就是已经完整收到几条记录。
 * 不找键名、不 JSON.parse，跨分片保持状态；第一个 `{` 之前的废话（```json）不算。
 */
function createRecordCounter() {
  let depth = 0;
  let inStr = false;
  let esc = false;
  let started = false;
  let count = 0;
  const stack = [];
  return {
    push(chunk) {
      for (const c of String(chunk)) {
        if (!started) {
          if (c !== '{') continue;
          started = true;
        }
        if (inStr) {
          if (esc) esc = false;
          else if (c === '\\') esc = true;
          else if (c === '"') inStr = false;
          continue;
        }
        if (c === '"') inStr = true;
        else if (c === '{' || c === '[') {
          stack.push(c);
          depth++;
        } else if (c === '}' || c === ']') {
          const open = stack.pop();
          depth--;
          // 闭合的是第 3 层的对象，而且它外面（第 2 层）是数组：一条记录收齐了。
          if (c === '}' && open === '{' && depth === 2 && stack[1] === '[') count++;
        }
      }
      return count;
    },
    get count() {
      return count;
    },
  };
}

module.exports = { parseImportOutput, createRecordCounter };
