'use strict';

// 类别 = 花在什么上（餐饮、交通…）。收入与支出各一套，`parentId` 预留给二级
// 类别，服务端不强制层级，只存。

const { HttpError } = require('../lib/router');
const { makeCrud } = require('../lib/crud');

module.exports = (ctx) => {
  const { db } = ctx;

  const crud = makeCrud({
    db,
    table: 'categories',
    resource: 'categories',
    singular: 'category',
    label: '类别',
    fields: {
      name: { type: 'string', required: true, max: 40 },
      kind: { type: 'enum', values: ['expense', 'income'], required: true },
      parentId: { type: 'id' },
      icon: { type: 'string', max: 40 },
      color: { type: 'color' },
    },

    canDelete(row) {
      const used = db.get(
        "SELECT 1 AS ok FROM transactions WHERE deleted_at IS NULL AND status = 'confirmed' AND category_id = ? LIMIT 1",
        row.id,
      );
      if (used) {
        throw new HttpError(409, 'category_in_use', '该类别下已有流水，不能删除；可以改成「归档」');
      }
    },
  });

  return { name: 'categories', routes: crud.routes };
};
