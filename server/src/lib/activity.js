'use strict';

// The audit trail. One row per meaningful write, deliberately tiny: who did
// what to which entity, and when. It is not synced and nothing reads it back
// yet — it exists so "谁把这笔改了" is answerable after the fact.

/**
 * @param {object} db handle from lib/db.js
 * @param {{memberId?: string|null, action: string, entity: string, entityId?: string|null, at?: string}} e
 */
function logActivity(db, { memberId = null, action, entity, entityId = null, at = null }) {
  db.run(
    'INSERT INTO activity(member_id, action, entity, entity_id, at) VALUES(?, ?, ?, ?, ?)',
    memberId, action, entity, entityId, at || db.now(),
  );
}

module.exports = { logActivity };
