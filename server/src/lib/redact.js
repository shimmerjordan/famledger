'use strict';

// 发给模型之前的脱敏（spec §4「日志」）：手机号打码，卡号只留尾号。AI 导入的原文（订单详情、权益说明）
// 常夹着收货电话和银行卡号，模型用不着它们。
//
//   redactPii(text) → { text, phones, cards }   phones / cards 是打了几处码（只给日志记个数）
//
// 先卡号再手机号：卡号是 13–19 位连续数字，或四位一组用空格 / 短横隔开（6222 0212 3456 7890）；手机号是 1 开头的
// 11 位（中间可以有空格或短横）。前后紧挨着数字的不认 —— 那是更长的一串（订单号里的一段不单独当手机号）。
// 19 位的订单号会被当成卡号打码，这是故意的：宁可多打一个码，订单号本来就不是要抽的东西。

const CARD_RE = /(?<!\d)(?:\d{13,19}|\d{4}(?:[ -]\d{4}){2,3}(?:[ -]\d{1,3})?)(?!\d)/g;
const PHONE_RE = /(?<!\d)1[3-9]\d(?:[ -]?\d{4}){2}(?!\d)/g;

function redactPii(text) {
  let cards = 0;
  let phones = 0;
  const out = String(text ?? '')
    .replace(CARD_RE, (m) => {
      cards++;
      const digits = m.replace(/\D/g, '');
      return `**** ${digits.slice(-4)}`;
    })
    .replace(PHONE_RE, (m) => {
      phones++;
      const digits = m.replace(/\D/g, '');
      return `${digits.slice(0, 3)}****${digits.slice(-4)}`;
    });
  return { text: out, phones, cards };
}

module.exports = { redactPii };
