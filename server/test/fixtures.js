'use strict';

// Shared bootstrap for the ledger/transactions/changes suites: a fresh server
// that has already run the setup wizard, plus the seeded fund / account /
// category every test needs to point a transaction at.

const assert = require('node:assert/strict');

const { startServer, api } = require('./helpers');

const SETUP = {
  householdName: '小明家',
  username: 'admin',
  password: 'hunter22',
  displayName: '小明',
};

/**
 * A running server with an initialised household.
 * @returns {Promise<{srv:object, a:object, token:string, auth:{token:string},
 *   member:object, funds:object[], accounts:object[], categories:object[],
 *   fund:object, account:object, category:object, tx:Function}>}
 */
async function household(t, env) {
  const srv = await startServer(env);
  t.after(() => srv.stop());
  const a = api(srv.base);

  const setup = await a.post('/setup', SETUP);
  assert.equal(setup.status, 200, `setup failed: ${setup.text}`);
  const token = setup.json.token;
  const auth = { token };

  const items = async (p) => {
    const r = await a.get(p, auth);
    assert.equal(r.status, 200, `GET ${p} → ${r.status} ${r.text}`);
    return r.json.items;
  };
  const funds = await items('/funds');
  const accounts = await items('/accounts');
  const categories = await items('/categories');

  return {
    srv, a, token, auth,
    member: setup.json.member,
    funds, accounts, categories,
    fund: funds[0], account: accounts[0], category: categories[0],
    /** POST /transactions with the token already attached. */
    tx: (body) => a.post('/transactions', body, auth),
    put: (p, body) => a.call('PUT', p, { token, body }),
  };
}

module.exports = { household, SETUP };
