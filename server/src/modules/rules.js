'use strict';

// 自动识别规则：通知/分享文本进来时按 priority 从小到大匹配，命中就把类别、
// 基金、账户、成员填上。匹配本身在客户端 capture 管线里跑，这里只负责存。

const { makeCrud } = require('../lib/crud');
const v = require('../lib/validate');

module.exports = (ctx) => {
  const { db } = ctx;

  const crud = makeCrud({
    db,
    table: 'rules',
    resource: 'rules',
    singular: 'rule',
    label: '规则',
    listOrder: 'priority ASC, created_at ASC',
    archived: false,     // rules 表没有 archived 列，停用走 enabled
    sortColumn: null,    // 顺序由 priority 决定，不需要 reorder 路由
    fields: {
      priority: { type: 'int', min: 0, max: 100000, default: 100 },
      field: { type: 'enum', values: ['merchant', 'text', 'app'], required: true },
      op: { type: 'enum', values: ['contains', 'regex'], default: 'contains' },
      pattern: { type: 'string', required: true, max: 200 },
      categoryId: { type: 'id' },
      fundId: { type: 'id' },
      accountId: { type: 'id' },
      memberId: { type: 'id' },
      enabled: { type: 'bool', default: true },
    },

    /** A regex that does not compile would throw once per captured notification. */
    fromBody(body, isPatch, row) {
      const op = body.op ?? row?.op ?? 'contains';
      const pattern = body.pattern ?? row?.pattern;
      if (op === 'regex' && typeof pattern === 'string') {
        try {
          new RegExp(pattern);
        } catch (e) {
          v.bad('pattern', `正则表达式无效：${e.message}`);
        }
      }
      return {};
    },
  });

  return { name: 'rules', routes: crud.routes };
};
