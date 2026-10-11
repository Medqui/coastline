const { test } = require('node:test');
const assert = require('node:assert/strict');
const ts = require('typescript');
const fs = require('node:fs');
const path = require('node:path');

function load(relative, imports = {}) {
  const source = fs.readFileSync(path.join(__dirname, '..', relative), 'utf8');
  const module = { exports: {} };
  const compiled = ts.transpileModule(source, { compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2021 } }).outputText;
  new Function('exports', 'module', 'require', compiled)(module.exports, module, name => {
    if (!(name in imports)) throw new Error(`Unexpected import ${name}`);
    return imports[name];
  });
  return module.exports;
}
const types = load('lib/saas/types.ts');
const upgrades = load('lib/saas/upgrades.ts', { './types': types });
const pricing = load('lib/saas/pricing.ts');
const subscription = { plan_code: 'starter', status: 'active', access: 'full', features: [] };
const codes = sub => upgrades.availableUpgradePlans(sub).map(plan => plan.code);

test('paid upgrades go up a tier, and Group has no higher tier', () => {
  assert.deepEqual(codes(subscription), ['business', 'group']);
  assert.deepEqual(codes({ ...subscription, plan_code: 'business' }), ['group']);
  assert.deepEqual(codes({ ...subscription, plan_code: 'group' }), []);
});
test('trial and pilot customers can activate their existing tier without a downgrade', () => {
  assert.deepEqual(codes({ ...subscription, plan_code: 'business', status: 'trialing' }), ['business', 'group']);
  assert.deepEqual(codes({ ...subscription, plan_code: 'group', grandfathered: true }), ['group']);
});
test('billing dates use Lagos calendar days and cannot activate an already ended period', () => {
  assert.equal(upgrades.billingDateInput('2026-10-11T23:30:00Z'), '2026-10-12');
  const now = Date.parse('2026-10-11T12:00:00+01:00');
  assert.equal(upgrades.upgradeEndDateError('', now), null);
  assert.equal(upgrades.upgradeEndDateError('2026-10-11', now), null);
  assert.ok(upgrades.upgradeEndDateError('2026-10-10', now));
});

function server({ signedIn = true, admin = true, hotelSubscription = subscription, saveError = null } = {}) {
  const calls = [];
  const refreshed = [];
  const db = {
    auth: { getUser: async () => ({ data: { user: signedIn ? { id: 'admin' } : null } }) },
    rpc: async (name, args) => {
      calls.push({ name, args });
      if (name === 'is_platform_admin') return { data: admin, error: null };
      if (name === 'get_platform_overview') return { data: { hotels: [{ id: 'customer', is_test: true, subscription: hotelSubscription }] }, error: null };
      if (name === 'set_platform_subscription') return { error: saveError };
      throw new Error(`Unexpected RPC ${name}`);
    },
  };
  const { updateSubscription } = load('app/platform/actions.ts', {
    'next/cache': { revalidatePath: route => refreshed.push(route) },
    '@/lib/supabase/server': { createClient: async () => db },
    '@/lib/saas/types': types,
    '@/lib/saas/upgrades': upgrades,
    '@/lib/saas/pricing': pricing,
  });
  return { action: updateSubscription, calls, refreshed };
}
function form(values = {}) {
  const data = new FormData();
  Object.entries({ organization_id: 'customer', intent: 'upgrade', plan: 'business', reason: 'Customer requested an upgrade', monthly_fee: '1000.50', period_end: '', ...values }).forEach(([name, value]) => data.set(name, value));
  return data;
}
test('sign-in and platform administration are required before any subscription write', async () => {
  for (const settings of [{ signedIn: false }, { admin: false }]) {
    const api = server(settings);
    assert.ok((await api.action({}, form())).error);
    assert.equal(api.calls.filter(call => call.name === 'set_platform_subscription').length, 0);
  }
});
test('admin upgrade activates access, preserves test classification, saves exact kobo and refreshes both dashboards', async () => {
  const api = server();
  const result = await api.action({}, form({ status: 'expired', is_test: '' }));
  assert.deepEqual(result, { success: true, planName: 'Business' });
  const write = api.calls.find(call => call.name === 'set_platform_subscription').args;
  assert.equal(write.p_status, 'active');
  assert.equal(write.p_plan_code, 'business');
  assert.equal(write.p_is_test, true);
  assert.equal(write.p_monthly_fee_kobo, 100050);
  assert.equal(write.p_period_end, null);
  assert.deepEqual(api.refreshed, ['/platform', '/subscription', '/']);
});
test('fresh database plan checks reject stale upgrade choices and lower tiers', async () => {
  const api = server({ hotelSubscription: { ...subscription, plan_code: 'group' } });
  assert.ok((await api.action({}, form())).error);
  assert.equal(api.calls.some(call => call.name === 'set_platform_subscription'), false);
});
test('expired dates, missing reasons and invalid pricing cannot save an upgrade', async () => {
  for (const invalid of [{ period_end: '2000-01-01' }, { period_end: '2026-02-30' }, { reason: ' ' }, { monthly_fee: '-1' }, { monthly_fee: '1.001' }, { plan: 'fake' }]) {
    const api = server();
    assert.ok((await api.action({}, form(invalid))).error);
    assert.equal(api.calls.some(call => call.name === 'set_platform_subscription'), false);
  }
});
test('database capacity failures remain visible and do not report success', async () => {
  const api = server({ saveError: { message: 'This hotel exceeds the selected plan limits.' } });
  assert.deepEqual(await api.action({}, form()), { error: 'This hotel exceeds the selected plan limits.' });
  assert.deepEqual(api.refreshed, []);
});

test('launch prices and currency conversion preserve exact agreed amounts', () => {
  assert.deepEqual(pricing.launchPrices, { starter: 1500000, business: 3500000, group: 7500000 });
  assert.equal(pricing.parseAmountKobo('35000.01'), 3500001);
  assert.equal(pricing.parseAmountKobo('75000'), 7500000);
  for (const value of ['-1', '10.001', '1e3', 'not-money', '9007199254740991']) assert.equal(pricing.parseAmountKobo(value), null);
});
function receiptServer({ admin = true, signedIn = true, error = null } = {}) {
  const writes = [], refreshed = [];
  const db = {
    auth: { getUser: async () => ({ data: { user: signedIn ? { id: 'platform-admin' } : null } }) },
    rpc: async (name, args) => {
      if (name === 'is_platform_admin') return { data: admin, error: null };
      if (name !== 'record_subscription_receipt') throw new Error(`Unexpected RPC ${name}`);
      writes.push(args); return { data: 'recorded-receipt', error };
    },
  };
  const { recordSubscriptionReceipt } = load('app/platform/actions.ts', {
    'next/cache': { revalidatePath: route => refreshed.push(route) },
    '@/lib/supabase/server': { createClient: async () => db },
    '@/lib/saas/types': types, '@/lib/saas/upgrades': upgrades, '@/lib/saas/pricing': pricing,
  });
  return { action: recordSubscriptionReceipt, writes, refreshed };
}
function receiptForm(values = {}) {
  const data = new FormData();
  Object.entries({ request_id: '21000000-0000-4000-8000-000000000010', organization_id: '21000000-0000-4000-8000-000000000001', entry_type: 'payment', plan: 'business', amount: '35000.01', received_on: '2026-10-11', method: 'bank_transfer', reference: 'UNIQUE-TEST-REFERENCE', note: 'Verified subscription transfer', ...values }).forEach(([name, value]) => data.set(name, value));
  return data;
}
test('only signed-in platform admins can submit receipt entries', async () => {
  for (const settings of [{ signedIn: false }, { admin: false }]) {
    const api = receiptServer(settings);
    assert.ok((await api.action({}, receiptForm())).error);
    assert.deepEqual(api.writes, []);
  }
});
test('receipt submissions use integer kobo and carry an idempotency request ID', async () => {
  const api = receiptServer();
  assert.deepEqual(await api.action({}, receiptForm()), { success: true, receiptId: 'recorded-receipt' });
  assert.equal(api.writes[0].p_amount_kobo, 3500001);
  assert.equal(api.writes[0].p_request_id, '21000000-0000-4000-8000-000000000010');
  assert.equal(api.writes[0].p_original_payment_id, null);
  assert.deepEqual(api.refreshed, ['/platform']);
});
test('refund entries require the original payment and propagate duplicate or excess-refund errors', async () => {
  const missing = receiptServer();
  assert.ok((await missing.action({}, receiptForm({ entry_type: 'refund' }))).error);
  assert.deepEqual(missing.writes, []);
  const failed = receiptServer({ error: { message: 'Refund exceeds the remaining amount.' } });
  assert.deepEqual(await failed.action({}, receiptForm({ entry_type: 'refund', original_payment_id: '21000000-0000-4000-8000-000000000011' })), { error: 'Refund exceeds the remaining amount.' });
  assert.deepEqual(failed.refreshed, []);
});
test('invalid receipt identifiers, money, calendar dates and notes are rejected before a write', async () => {
  for (const invalid of [{ request_id: '' }, { organization_id: 'invalid' }, { amount: '0' }, { amount: '1.001' }, { received_on: '2026-02-30' }, { entry_type: 'charge' }, { reference: ' ' }, { note: ' ' }]) {
    const api = receiptServer();
    assert.ok((await api.action({}, receiptForm(invalid))).error);
    assert.deepEqual(api.writes, []);
  }
});
