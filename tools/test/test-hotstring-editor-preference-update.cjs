// tools/test/test-hotstring-editor-preference-update.cjs

/** Checks that host preference updates preserve the live unsaved editor model. */
'use strict';
const assert = require('assert');
const fs = require('fs');
const path = require('path');
const vm = require('vm');
const script = path.resolve(
	__dirname,
	'../../static/ergopti_plus/_shared/ui/hotstring_editor/script.js'
);
const source = fs.readFileSync(script, 'utf8');
const marker = source.indexOf('// ======= 15/ Event Wiring');
assert(marker > 0);
const context = vm.createContext({
	document: {},
	makeHostBridge: () => () => {},
	setTimeout() {},
	clearTimeout() {}
});
context.window = context;
vm.runInContext(source.slice(0, marker), context);
vm.runInContext(
	`
 D = { sections: [{ name: 'Draft', entries: [{ trigger: 'unsaved' }] }] };
 updateHints = function () {};
 updateCompactBtn = function () {};
 render = function () {};
 window.updatePreferences({ trigger_char: '#', compact_view: true, auto_close: false });
 if (D.sections[0].entries[0].trigger !== 'unsaved') throw new Error('draft lost');
 if (TRIGGER_CHAR !== '#' || compactView !== true) throw new Error('preferences not applied');
`,
	context
);
console.log('hotstring editor preference update preserves unsaved document');
