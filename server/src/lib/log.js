'use strict';

// Tiny leveled logger. One line per event, ISO timestamp, no deps.
// LOG_LEVEL=trace|debug|info|warn|error (default info).
//
// The five levels are distinct on purpose: `trace` is per-request firehose
// (every SQL statement, every capture candidate), `debug` is the level you can
// actually leave on while reproducing something. An unknown LOG_LEVEL falls
// back to info rather than silencing the process.

const LEVELS = { trace: 0, debug: 1, info: 2, warn: 3, error: 4 };
const threshold = LEVELS[(process.env.LOG_LEVEL || 'info').toLowerCase()] ?? LEVELS.info;

function emit(level, tag, msg) {
  if (LEVELS[level] < threshold) return;
  const line = `${new Date().toISOString()} [${level}] [${tag}] ${msg}`;
  if (level === 'error' || level === 'warn') process.stderr.write(line + '\n');
  else process.stdout.write(line + '\n');
}

module.exports = {
  trace: (tag, msg) => emit('trace', tag, msg),
  debug: (tag, msg) => emit('debug', tag, msg),
  info: (tag, msg) => emit('info', tag, msg),
  warn: (tag, msg) => emit('warn', tag, msg),
  error: (tag, msg) => emit('error', tag, msg),
};
