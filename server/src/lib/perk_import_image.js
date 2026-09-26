'use strict';

// 截图导入的图片校验（spec §6「截图」）。App 已经切片、缩到长边 ≤1568 并编成 PNG；这里只守门，不解码、不缩放：
//   · 最多 MAX_IMAGES 片（App 那边「合计最多 8 片」）；
//   · data 是 base64（不带 data: 前缀；带了也认，剥掉）；
//   · 看文件头认类型：PNG / JPEG / WebP，别的 400 —— mediaType 以文件头为准，不信请求里写的；
//   · 单张解码后 ≤ MAX_IMAGE_BYTES（3.75MB：base64 之后正好 5MB，是上游单张图的上限）；
//   · 宽高每边 1..MAX_PNG_EDGE（2000）：PNG 读 IHDR（再顺着块长度走到 IEND，头对、后面是垃圾的挡掉），
//     JPEG 找 SOF 段，WebP 读 VP8 / VP8L / VP8X 头 —— 都只读头，不解码。读不出尺寸的当坏图。
//     App 只发 PNG、长边 ≤1568；这道闸防的是别的客户端（或 App 以后回归）把上游一定会拒的图发出去：
//     到上游才 400 的话，限流名额和 token 已经扣了。
//
//   readImages(raw) → [{mediaType, data, bytes, width, height}]
//   出错一律 400 invalid_images（v.bad），消息写明第几张、哪里不对。

const v = require('./validate');

const MAX_IMAGES = 8;
const MAX_IMAGE_BYTES = Math.floor(3.75 * 1024 * 1024);
const MAX_PNG_EDGE = 2000;
const PNG_MAGIC = Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]);
const BASE64 = /^[A-Za-z0-9+/]*={0,2}$/;

/** 文件头 → mediaType；认不出回 null。 */
function sniff(buf) {
  if (buf.length >= 24 && buf.subarray(0, 8).equals(PNG_MAGIC)) return 'image/png';
  if (buf.length >= 3 && buf[0] === 0xff && buf[1] === 0xd8 && buf[2] === 0xff) return 'image/jpeg';
  if (buf.length >= 12 && buf.toString('latin1', 0, 4) === 'RIFF' && buf.toString('latin1', 8, 12) === 'WEBP') return 'image/webp';
  return null;
}

/** PNG 的 IHDR（紧跟在 8 字节签名后面的第一块）里的宽高；不是合法的 IHDR 回 null。 */
function pngSize(buf) {
  if (buf.length < 24 || buf.readUInt32BE(8) !== 13 || buf.toString('latin1', 12, 16) !== 'IHDR') return null;
  return { width: buf.readUInt32BE(16), height: buf.readUInt32BE(20) };
}

/** PNG 的块结构走得通：每块的长度都在文件里，最后走到 IEND（不校验 CRC、不解压）。 */
function pngChunksOk(buf) {
  let i = 8;
  while (i + 12 <= buf.length) {
    const len = buf.readUInt32BE(i);
    const type = buf.toString('latin1', i + 4, i + 8);
    if (!/^[A-Za-z]{4}$/.test(type) || i + 12 + len > buf.length) return false;
    if (type === 'IEND') return true;
    i += 12 + len;
  }
  return false;
}

/** SOFn 段（不含 DHT / JPG / DAC 这几个撞号的）。 */
const JPEG_SOF = new Set([0xc0, 0xc1, 0xc2, 0xc3, 0xc5, 0xc6, 0xc7, 0xc9, 0xca, 0xcb, 0xcd, 0xce, 0xcf]);

/** JPEG 顺着段长度找第一个 SOF 段里的宽高；在 SOF 之前遇到 SOS / EOI、段长度不对都回 null。 */
function jpegSize(buf) {
  let i = 2;
  while (i + 4 <= buf.length) {
    if (buf[i] !== 0xff) return null;
    const marker = buf[i + 1];
    if (marker === 0xff) {
      i += 1; // 填充字节
      continue;
    }
    if (marker === 0x01 || (marker >= 0xd0 && marker <= 0xd8)) {
      i += 2; // 没有长度的独立标记
      continue;
    }
    if (marker === 0xd9 || marker === 0xda) return null;
    const len = buf.readUInt16BE(i + 2);
    if (len < 2 || i + 2 + len > buf.length) return null;
    if (JPEG_SOF.has(marker)) {
      if (len < 7) return null;
      return { width: buf.readUInt16BE(i + 7), height: buf.readUInt16BE(i + 5) };
    }
    i += 2 + len;
  }
  return null;
}

/** WebP 的画布尺寸：有损 VP8、无损 VP8L、扩展 VP8X 三种头各读各的。 */
function webpSize(buf) {
  if (buf.length < 30) return null;
  const chunk = buf.toString('latin1', 12, 16);
  if (chunk === 'VP8 ') {
    if (buf[23] !== 0x9d || buf[24] !== 0x01 || buf[25] !== 0x2a) return null;
    return { width: buf.readUInt16LE(26) & 0x3fff, height: buf.readUInt16LE(28) & 0x3fff };
  }
  if (chunk === 'VP8L') {
    if (buf[20] !== 0x2f) return null;
    const bits = buf.readUInt32LE(21);
    return { width: (bits & 0x3fff) + 1, height: ((bits >>> 14) & 0x3fff) + 1 };
  }
  if (chunk === 'VP8X') return { width: buf.readUIntLE(24, 3) + 1, height: buf.readUIntLE(27, 3) + 1 };
  return null;
}

const SIZE_OF = { 'image/png': pngSize, 'image/jpeg': jpegSize, 'image/webp': webpSize };
const LABEL = { 'image/png': 'PNG', 'image/jpeg': 'JPEG', 'image/webp': 'WebP' };

const mb = (n) => (n / 1024 / 1024).toFixed(2).replace(/\.?0+$/, '');

function readImages(raw) {
  const list = v.list(raw, 'images', { max: 1000 });
  if (list.length > MAX_IMAGES) v.bad('images', `一次最多 ${MAX_IMAGES} 片截图`);
  if (!list.length) v.bad('images', '至少选一张截图');
  return list.map((img, i) => {
    const no = i + 1;
    const rawData = v.isObject(img) ? img.data : img;
    if (typeof rawData !== 'string' || !rawData) v.bad('images', `第 ${no} 张图没有数据`);
    const data = rawData.startsWith('data:') ? rawData.slice(rawData.indexOf(',') + 1) : rawData;
    // 先按长度估一下，别为一张明显超大的图去解码。
    if (Math.floor((data.length * 3) / 4) > MAX_IMAGE_BYTES + 3) {
      v.bad('images', `第 ${no} 张图有 ${mb((data.length * 3) / 4)}MB，单张不能超过 3.75MB`);
    }
    if (data.length % 4 !== 0 || !BASE64.test(data)) v.bad('images', `第 ${no} 张图的数据坏了（不是 base64）`);
    const buf = Buffer.from(data, 'base64');
    if (buf.length > MAX_IMAGE_BYTES) v.bad('images', `第 ${no} 张图有 ${mb(buf.length)}MB，单张不能超过 3.75MB`);
    const mediaType = sniff(buf);
    if (!mediaType) v.bad('images', `第 ${no} 张不是 PNG、JPEG 或 WebP 图片`);
    const size = SIZE_OF[mediaType](buf);
    if (!size || (mediaType === 'image/png' && !pngChunksOk(buf))) v.bad('images', `第 ${no} 张 ${LABEL[mediaType]} 的文件坏了`);
    const { width, height } = size;
    if (width < 1 || height < 1) v.bad('images', `第 ${no} 张图的尺寸是 ${width}×${height}，文件坏了`);
    if (width > MAX_PNG_EDGE || height > MAX_PNG_EDGE) {
      v.bad('images', `第 ${no} 张图是 ${width}×${height}，每边不能超过 ${MAX_PNG_EDGE} 像素`);
    }
    return { mediaType, data, bytes: buf.length, width, height };
  });
}

module.exports = { readImages, sniff, pngSize, jpegSize, webpSize, MAX_IMAGES, MAX_IMAGE_BYTES, MAX_PNG_EDGE };
