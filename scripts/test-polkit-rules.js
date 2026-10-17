// Executes the polkit rules against a mock polkit object and checks decisions.
const fs = require('fs');
const src = fs.readFileSync(process.argv[2], 'utf8');
const rules = [];
const polkit = { Result: { YES: 'yes', NO: 'no', NOT_HANDLED: null }, addRule: f => rules.push(f), log: () => {} };
new Function('polkit', src)(polkit);
function decide(id, user, extra = {}, local = true, active = true) {
  const action = { id, lookup: k => extra[k] };
  const subject = { user, local, active };
  for (const r of rules) { const v = r(action, subject); if (v !== null && v !== undefined) return v; }
  return null;
}
const cases = [
  ['org.freedesktop.login1.power-off', 'steamos', {}, true, true, 'yes'],
  ['org.freedesktop.login1.reboot', 'steamos', {}, true, true, 'yes'],
  ['org.freedesktop.login1.suspend', 'steamos', {}, true, true, 'yes'],
  ['org.freedesktop.login1.power-off', 'steamos', {}, false, true, null],   // remote (ssh) session: not auto-allowed
  ['org.freedesktop.login1.power-off', 'other', {}, true, true, null],
  ['org.freedesktop.policykit.exec', 'steamos', { program: '/usr/bin/steamos-polkit-helpers/steamos-set-session' }, true, true, 'yes'],
  ['org.freedesktop.policykit.exec', 'steamos', { program: '/usr/bin/bash' }, true, true, null],
  ['org.freedesktop.NetworkManager.network-control', 'steamos', {}, true, true, 'yes'],
  ['org.freedesktop.udisks2.modify-device', 'steamos', {}, true, true, null],
];
let fail = 0;
for (const [id, u, ex, l, a, want] of cases) {
  const got = decide(id, u, ex, l, a);
  const ok = got === want; if (!ok) fail++;
  console.log(`${ok ? 'PASS' : 'FAIL'} ${id} user=${u} local=${l} -> ${got} (want ${want})`);
}
process.exit(fail ? 1 : 0);
