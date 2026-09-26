'use strict';

// 看图探测的判定（spec §4 `POST /ai/providers/:id/test?vision=1`）：发一张 2×2 的纯红 PNG，问「这张图是什么颜色？只回答一个颜色词。」
// 只有明确把「红色 / red」当答案说出来才算能看图。看不了图的模型（或者兼容端把图片悄悄丢掉）常见的回答都要判成 false：
//   · 否定、拒答：「不是红色」「我看不到图片」「I cannot see any image」「I don't see red」；
//   · 反问、猜测：「是红色吗？」「可能是红色」「probably red」；
//   · 子串撞上：delivered / rendered / colored 里的 red 不算（英文按整词认）；
//   · 同时说了别的颜色：「红色或白色」「red and blue」（纯红图不会看出第二种颜色，这是在猜）。
//
//   judgeVisionAnswer(sample) → true | false     sample 是模型回答的原文（空串由调用方先拦，判「判断不了」）

const RED = /红|\b(?:red|reddish|crimson|scarlet)\b/i;
const NEGATION = /不|没|沒|无|無|未能|看不|抱歉|对不起|\b(?:no|not|cannot|unable|without|sorry|unfortunately)\b|n['’]t\b/i;
const QUESTION = /[?？]|吗|嗎|呢/;
const HEDGE = /可能|也许|也許|或许|或許|大概|应该|應該|猜|\b(?:maybe|perhaps|probably|possibly|might|guess)\b/i;
const OTHER_COLOR = /蓝|藍|绿|綠|黄|黃|白|黑|灰|紫|橙|粉|棕|褐|青|金|银|銀|\b(?:blue|green|yellow|white|black|gr[ae]y|purple|violet|orange|pink|brown|cyan|magenta|gold|silver)\b/i;

function judgeVisionAnswer(sample) {
  const text = String(sample ?? '').normalize('NFKC').trim();
  if (!text || !RED.test(text)) return false;
  return !NEGATION.test(text) && !QUESTION.test(text) && !HEDGE.test(text) && !OTHER_COLOR.test(text);
}

module.exports = { judgeVisionAnswer };
