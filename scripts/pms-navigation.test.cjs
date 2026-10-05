const { test } = require('node:test');
const assert = require('node:assert/strict');
const ts = require('typescript');
const fs = require('node:fs');
const source = fs.readFileSync(require('node:path').join(__dirname, '../lib/pms-navigation.ts'), 'utf8');
const moduleObject = { exports: {} };
new Function('exports', 'module', ts.transpileModule(source, { compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2021 } }).outputText)(moduleObject.exports, moduleObject);
const { screens, parseScreen, canViewScreen, roomState } = moduleObject.exports;
test('MVP menu has the exact order', () => assert.deepEqual(screens, ['Dashboard','Reservations','Front Desk','Rooms','Housekeeping','POS','Accounting','Inventory','Reports','Staff','Settings']));
test('direct hashes obey the user role', () => {
  assert.equal(parseScreen('#settings','front_desk'),'Dashboard');
  assert.equal(parseScreen('#front-desk','front_desk'),'Front Desk');
  assert.equal(parseScreen('#reports','accountant'),'Reports');
  assert.equal(canViewScreen('Settings','manager'),true);
  assert.equal(canViewScreen('POS','housekeeping'),false);
  assert.equal(canViewScreen('Inventory','accountant'),true);
  assert.equal(canViewScreen('Settings','unknown'),false);
});
const room = { id:'room',status:'clean' };
const stay = {roomId:'room',status:'confirmed',arrivalDate:'2026-10-05',departureDate:'2026-10-07'};
test('future reservations do not hide today’s available room', () => assert.equal(roomState(room,[{...stay,arrivalDate:'2026-10-06'}],'2026-10-05'),'Available'));
test('today’s reservations count as reserved until departure', () => {
  assert.equal(roomState(room,[stay],'2026-10-05'),'Reserved');
  assert.equal(roomState(room,[stay],'2026-10-07'),'Available');
});
test('cleanliness and maintenance remain distinct from occupancy', () => {
  assert.equal(roomState({...room,status:'dirty'},[stay],'2026-10-05'),'Dirty');
  assert.equal(roomState({...room,maintenanceBlocked:true},[stay],'2026-10-05'),'Maintenance');
  assert.equal(roomState({...room,status:'dirty'},[{...stay,status:'checked_in'}],'2026-10-05'),'Occupied');
  assert.equal(roomState(room,[{...stay,status:'cancelled'}],'2026-10-05'),'Available');
});
