'use strict';

// 看图探测的判定（lib/vision_probe.js，spec §4 `?vision=1`）：只有明确把「红色 / red」当答案说出来才算能看图。
// 看不了图的模型（或兼容端把图片悄悄丢掉）常见的回答 —— 否定、拒答、反问、猜测、英文单词里撞上 red、同时说了别的颜色 —— 都判 false。

const test = require('node:test');
const assert = require('node:assert/strict');

const { judgeVisionAnswer } = require('../src/lib/vision_probe');

const CASES = [
  // 能看图：明确答红
  ['红色', true],
  ['红', true],
  ['红色。', true],
  ['**红色**', true],
  ['这张图是纯红色的。', true],
  ['看起来是红色', true],
  ['大红色', true],
  ['Red', true],
  ['red.', true],
  ['RED', true],
  ['The image is red.', true],
  ['Solid red (#FF0000).', true],
  ['Crimson', true],
  ['ｒｅｄ', true], // 全角也认（NFKC）
  // 否定、拒答
  ['不是红色', false],
  ['我看不到图片，无法判断是不是红色', false],
  ['没有看到图片', false],
  ['抱歉，我无法查看图片。', false],
  ['I cannot see any image, so I can\'t say whether it is red.', false],
  ["I don't see an image, but red is a common answer", false],
  ['It is not red.', false],
  ['Sorry, no image was provided. Red?', false],
  // 反问、猜测
  ['是红色吗？', false],
  ['红色？', false],
  ['可能是红色', false],
  ['应该是红色', false],
  ['Probably red', false],
  ['Maybe red', false],
  // 子串撞上（英文按整词认）
  ['I cannot see any image; nothing was delivered.', false],
  ['The image was not rendered.', false],
  ['colored', false],
  ['The picture is blank; it was never delivered', false],
  // 说了别的颜色、根本没提红
  ['红色和白色', false],
  ['red and blue', false],
  ['粉红色', false],
  ['蓝色', false],
  ['white', false],
  ['看不到图片，可能是白色', false],
  ['', false],
  ['   ', false],
];

test('判定表：明确答红 → true；否定 / 拒答 / 反问 / 猜测 / 子串 / 别的颜色 → false', () => {
  for (const [sample, want] of CASES) {
    assert.equal(judgeVisionAnswer(sample), want, `「${sample}」应该判 ${want}`);
  }
});

test('不是字符串也不抛：null / undefined / 数字都判 false', () => {
  for (const v of [null, undefined, 0, {}]) assert.equal(judgeVisionAnswer(v), false);
});
