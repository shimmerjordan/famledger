'use strict';

// The instance secret: 32 random bytes in `DATA_DIR/secret.key`, used to sign
// session tokens and to encrypt AI provider API keys at rest. Losing the file
// logs everyone out and makes stored keys unreadable, which is why it is
// created once and never rewritten.

const crypto = require('node:crypto');
const fs = require('node:fs');
const path = require('node:path');

const KEY_FILE = 'secret.key';
const ENC_PREFIX = 'enc:v1:';

/** @returns {Buffer} 32 bytes */
function loadOrCreateSecret(dataDir) {
  const file = path.join(path.resolve(dataDir), KEY_FILE);
  fs.mkdirSync(path.dirname(file), { recursive: true });
  for (let attempt = 0; attempt < 2; attempt++) {
    try {
      const hex = fs.readFileSync(file, 'utf8').trim();
      if (!/^[0-9a-fA-F]{64}$/.test(hex)) {
        throw new Error(`${file} is not a 32-byte hex key — refusing to overwrite it`);
      }
      return Buffer.from(hex, 'hex');
    } catch (e) {
      if (e.code !== 'ENOENT') throw e;
    }
    try {
      // `wx` so two processes starting together cannot both win; the loser
      // falls back to reading what the winner wrote.
      fs.writeFileSync(file, crypto.randomBytes(32).toString('hex') + '\n', { mode: 0o600, flag: 'wx' });
    } catch (e) {
      if (e.code !== 'EEXIST') throw e;
    }
  }
  throw new Error(`could not create ${file}`);
}

/** AES-256-GCM under a key derived from the instance secret. */
function encKey(secret) {
  return crypto.createHash('sha256').update(secret).update('famledger/enc/v1').digest();
}

/** @returns {string} `enc:v1:<base64(iv|tag|ciphertext)>` */
function encrypt(secret, plaintext) {
  const iv = crypto.randomBytes(12);
  const c = crypto.createCipheriv('aes-256-gcm', encKey(secret), iv);
  const ct = Buffer.concat([c.update(String(plaintext), 'utf8'), c.final()]);
  return ENC_PREFIX + Buffer.concat([iv, c.getAuthTag(), ct]).toString('base64');
}

/** @returns {string|null} null for an empty value; throws if tampered with. */
function decrypt(secret, enc) {
  if (enc === null || enc === undefined || enc === '') return null;
  if (typeof enc !== 'string' || !enc.startsWith(ENC_PREFIX)) {
    throw new Error('not an enc:v1 value');
  }
  const raw = Buffer.from(enc.slice(ENC_PREFIX.length), 'base64');
  if (raw.length < 28) throw new Error('enc:v1 value truncated');
  const d = crypto.createDecipheriv('aes-256-gcm', encKey(secret), raw.subarray(0, 12));
  d.setAuthTag(raw.subarray(12, 28));
  return Buffer.concat([d.update(raw.subarray(28)), d.final()]).toString('utf8');
}

/** True for values produced by `encrypt` (handy when a column may hold either). */
const isEncrypted = (v) => typeof v === 'string' && v.startsWith(ENC_PREFIX);

module.exports = { loadOrCreateSecret, encrypt, decrypt, isEncrypted, KEY_FILE };
