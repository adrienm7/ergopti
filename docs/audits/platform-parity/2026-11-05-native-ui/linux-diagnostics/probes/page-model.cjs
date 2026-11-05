const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const root = process.env.ERGOPTI_AUDIT_SOURCE_ROOT;
assert(root, 'explicit source root required');
const base = root + '/static/ergopti_plus/_shared/';
const page = { window: {} };
vm.runInNewContext(fs.readFileSync(base + 'ui/healthcheck/model.js', 'utf8'), page);
const model = page.window.ErgoptiDiagnostics;
const locale = JSON.parse(fs.readFileSync(base + 'data/locales/en.json', 'utf8'));
const t = (key) => locale[key] || key;
const data = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
const off = model.fieldDisplay(
	{ id: 'ai_enabled', type: 'bool' },
	data.off.sections.ai,
	data.off,
	t
);
const healthy = model.fieldDisplay(
	{ id: 'ai_enabled', type: 'bool' },
	{ ai_enabled: false },
	data.off,
	t
);
const absent = model.fieldDisplay(
	{ id: 'ai_enabled', type: 'bool' },
	data.absent.sections.ai,
	data.absent,
	t
);
assert.equal(off.text, t('healthcheck.value.unknown'));
assert.equal(off.state, 'muted');
assert.equal(healthy.text, t('healthcheck.value.no'));
assert.equal(healthy.state, 'value');
assert.equal(absent.text, off.text);
const api = model.fieldDisplay(
	{ id: 'ai_backend', type: 'text' },
	data.api.sections.ai,
	data.api,
	t
);
assert.equal(api.text, 'ollama');
console.log(
	'ADVERSE actual_page enabled=false renders=' +
		off.text +
		'/' +
		off.state +
		'; api renders=' +
		api.text
);
console.log('HEALTHY actual_page preserved_false renders=' + healthy.text + '/' + healthy.state);
console.log('REFUSAL actual_page absent_llm renders=' + absent.text + '/' + absent.state);
