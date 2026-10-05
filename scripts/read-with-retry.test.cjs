const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const ts = require('typescript');

// Execute the real helper without generating files or requiring a new test runtime.
const helper = fs.readFileSync(path.join(__dirname, '../lib/supabase/read-with-retry.ts'), 'utf8');
const compiled = ts.transpileModule(helper, { compilerOptions: { module: ts.ModuleKind.CommonJS } }).outputText;
function load() {
  const exports = {};
  const delays = [];
  vm.runInNewContext(compiled, { exports, TypeError, setTimeout: (callback, milliseconds) => {
    delays.push(milliseconds);
    callback();
  }});
  return { readWithRetry: exports.readWithRetry, delays };
}
const good = { status: 200, error: null, data: ['preserved'] };

test('successful read runs once and returns its exact response', async () => {
  const { readWithRetry, delays } = load(); let calls = 0;
  const result = await readWithRetry(() => { calls++; return Promise.resolve(good); });
  assert.equal(result, good); assert.equal(calls, 1); assert.deepEqual(delays, []);
});
test('temporary gateway failure rebuilds the query and recovers', async () => {
  const { readWithRetry, delays } = load(); let calls = 0;
  const result = await readWithRetry(() => Promise.resolve(++calls < 3 ? { status: 503, error: { message: 'Unavailable' } } : good));
  assert.equal(result, good); assert.equal(calls, 3); assert.deepEqual(delays, [250, 750]);
});
test('transport error response retries and retains successful data', async () => {
  const { readWithRetry } = load(); let calls = 0;
  assert.equal(await readWithRetry(() => Promise.resolve(++calls === 1 ? { status: 0, error: { code: '', message: 'TypeError: Failed to fetch' } } : good)), good);
  assert.equal(calls, 2);
});
test('rejected network fetch retries without logging response details', async () => {
  const { readWithRetry } = load(); let calls = 0;
  assert.equal(await readWithRetry(() => ++calls === 1 ? Promise.reject(new TypeError('fetch failed')) : Promise.resolve(good)), good);
  assert.equal(calls, 2);
});
test('exhausted temporary failures stop after three attempts', async () => {
  const { readWithRetry } = load(); let calls = 0;
  const failure = { status: 504, error: { message: 'Timeout' } };
  assert.equal(await readWithRetry(() => { calls++; return Promise.resolve(failure); }), failure);
  assert.equal(calls, 3);
});
test('permission, authentication, schema and database errors are not retried', async () => {
  for (const status of [400, 401, 403, 404, 500]) {
    const { readWithRetry, delays } = load(); let calls = 0;
    const failure = { status, error: { code: '42501', message: 'Database error' } };
    assert.equal(await readWithRetry(() => { calls++; return Promise.resolve(failure); }), failure);
    assert.equal(calls, 1); assert.deepEqual(delays, []);
  }
});
test('cancellation and programming errors are never retried', async () => {
  for (const failure of [new TypeError('Invalid data'), Object.assign(new Error('Aborted'), { name: 'AbortError' })]) {
    const { readWithRetry, delays } = load(); let calls = 0;
    await assert.rejects(readWithRetry(() => { calls++; return Promise.reject(failure); }), error => error === failure);
    assert.equal(calls, 1); assert.deepEqual(delays, []);
  }
});
test('rate limiting retries but unknown status-zero failures do not', async () => {
  const { readWithRetry } = load(); let calls = 0;
  assert.equal(await readWithRetry(() => Promise.resolve(++calls === 1 ? { status: 429, error: { message: 'Rate limit' } } : good)), good);
  const failure = { status: 0, error: { message: 'Unexpected error' } }; calls = 0;
  assert.equal(await readWithRetry(() => { calls++; return Promise.resolve(failure); }), failure);
  assert.equal(calls, 1);
});
