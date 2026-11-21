// tools/test/test-web-text-admission.cjs

/**
 * Execute the web text owners against literal input: the layout data loader,
 * the reference keyboard's lifecycle, the icon demo, and the Studio's
 * « Essayer » typist (layout_try/typing.js), whose typed text reaches the
 * text area as literal text. The former « Essayer » page's emulator and text
 * replacement viewer were retired with the page (maintainer, 2026-11-21).
 */
'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const { parse } = require('acorn');

const root = path.resolve(__dirname, '../..');

/**
 * Build the $app/paths asset() port of a site served under base, the way
 * SvelteKit resolves a static file on the client.
 * @param {string} base - The configured base path, empty at the site root.
 * @returns {(file: string) => string}
 */
function staticAsset(base) {
	return (file) => `${base}/${file}`;
}
async function checkLayoutDataRoutes() {
	const source = fs.readFileSync(
		path.join(root, 'src/lib/keyboard/data/getKeyboardData.js'),
		'utf8'
	);
	const owner = parse(source, { ecmaVersion: 'latest', sourceType: 'module' }).body.find(
		(node) =>
			node.type === 'ExportNamedDeclaration' && node.declaration?.id?.name === 'getKeyboardData'
	);
	assert.ok(owner, 'the actual layout loader is present');
	for (const base of ['', '/dev']) {
		const requests = [];
		const layout = { keys: [] };
		const realm = vm.createContext({
			asset: staticAsset(base),
			console: { info() {}, debug() {}, error() {} },
			fetch: async (url) => {
				requests.push(url);
				return { ok: true, status: 200, statusText: 'OK', json: async () => layout };
			}
		});
		vm.runInContext(source.slice(owner.declaration.start, owner.declaration.end), realm);
		assert.equal(await realm.getKeyboardData('2.2'), layout);
		assert.deepEqual(requests, [base + '/layouts/visualisation/ergopti_v2.2.json']);
	}
}

function checkKeyboardLifecycle() {
	const source = fs.readFileSync(path.join(root, 'src/lib/keyboard/Keyboard.js'), 'utf8');
	const owner = parse(source, { ecmaVersion: 'latest', sourceType: 'module' }).body.find(
		(node) => node.type === 'ExportNamedDeclaration' && node.declaration?.id?.name === 'Keyboard'
	);
	assert.ok(owner, 'the actual keyboard owner is present');
	const listeners = new Set();
	const store = {
		subscribe(callback) {
			const subscription = () => callback();
			listeners.add(subscription);
			callback();
			return () => listeners.delete(subscription);
		}
	};
	let element = null;
	let lookups = 0;
	let renders = 0;
	const realm = vm.createContext({
		stores_infos: { layoutData: store, fixture: store },
		console: { info() {}, error() {} },
		document: { getElementById: () => (++lookups, element) }
	});
	vm.runInContext(
		source.slice(owner.declaration.start, owner.declaration.end) + '\nthis.Subject = Keyboard;',
		realm
	);
	for (const name of ['updateKeys', 'updateKeyboardConfiguration', 'pressCurrentLayerModifiers'])
		realm.Subject.prototype[name] = () => renders++;
	const keyboard = new realm.Subject('fixture');
	assert.equal(listeners.size, 0, 'construction must not subscribe before the DOM is mounted');
	assert.equal(lookups, 0, 'construction must not inspect an absent DOM');
	element = {};
	keyboard.mount();
	assert.equal(listeners.size, 2);
	assert.equal(renders, 3, 'mount renders once after owning both subscriptions');
	assert.throws(() => keyboard.mount(), /already|initialized/i);
	const queued = [...listeners];
	for (const callback of queued) callback();
	assert.equal(renders, 9, 'both stores update the mounted keyboard');
	keyboard.destroy();
	assert.equal(listeners.size, 0, 'destroy retires both subscriptions');
	for (const callback of queued) callback();
	assert.equal(renders, 9, 'late queued callbacks cannot render the retired keyboard');
	assert.equal(keyboard.location, null);
	element = null;
	assert.throws(() => new realm.Subject('fixture').mount(), /mount|element|DOM/i);
	assert.equal(listeners.size, 0, 'failed mount leaves no subscriptions');
}

function checkLiteralDemo() {
	checkKeyboardLifecycle();
	const listeners = new Map();
	const drive = { style: {}, textContent: '\u00a0' };
	let markupWrites = 0;
	Object.defineProperty(drive, 'innerHTML', {
		set() {
			markupWrites += 1;
		}
	});
	const text = {
		value: '',
		addEventListener(event, callback) {
			listeners.set(event, callback);
		}
	};
	const font = {
		value: '48',
		addEventListener(event, callback) {
			listeners.set(`font:${event}`, callback);
		}
	};
	const ligatures = [];
	const demo = fs.readFileSync(path.join(root, 'src/lib/icons/icomoon/demo-files/demo.js'), 'utf8');
	vm.runInNewContext(demo, {
		document: {
			body: { style: { boxShadow: '' }, addEventListener() {} },
			getElementById(id) {
				return { fontSize: font, testDrive: drive, testText: text }[id];
			}
		},
		window: {
			icomoonLiga(element) {
				ligatures.push(element.textContent);
			}
		}
	});
	assert.equal(drive.style.fontSize, '48px');
	for (const event of ['input', 'change']) {
		text.value = '<img src=x onerror="throw new Error(1)"> & ligature';
		listeners.get(event)();
		assert.equal(markupWrites, 0, 'demo input never enters HTML parsing');
		assert.equal(drive.textContent, text.value, 'markup and ampersands remain literal demo text');
		assert.equal(ligatures.at(-1), text.value, 'the existing ligature hook observes literal text');
	}
	text.value = '';
	listeners.get('input')();
	assert.equal(drive.textContent, '\u00a0', 'the empty sample retains its nonbreaking-space glyph');
	font.value = '64';
	listeners.get('font:change')();
	assert.equal(drive.style.fontSize, '64px');
}

/** The Studio's typist returns a layout's text as it is, never as markup or an escape. */
function checkTryLiteral() {
	const realm = vm.createContext({});
	vm.runInContext(
		fs.readFileSync(path.join(root, 'static/ergopti_plus/_shared/ui/layout_try/typing.js'), 'utf8'),
		realm
	);
	const typist = realm.LAYOUT_TRY_TYPING.create({
		id: 'literal',
		rows: {
			KeyA: ['<img src=x onerror=1>', '&amp;', '\\n', null],
			KeyB: [{ dead: 'grave' }, null, null, null],
			Space: [' ', null, null, null]
		},
		dead: { grave: { ' ': '`', '<img src=x onerror=1>': '<b>' } }
	});
	assert.equal(typist.press('KeyA', {}).text, '<img src=x onerror=1>', 'markup stays text');
	assert.equal(typist.press('KeyA', { shift: true }).text, '&amp;', 'an entity stays text');
	assert.equal(typist.press('KeyA', { altgr: true }).text, '\\n', 'an escape is not decoded');
	assert.equal(
		typist.press('KeyA', { shift: true, altgr: true }).text,
		'',
		'an empty level types nothing'
	);
	typist.press('KeyB', {});
	assert.equal(typist.press('KeyA', {}).text, '<b>', "a dead key's rule stays text");
	const page = fs.readFileSync(
		path.join(root, 'static/ergopti_plus/_shared/ui/layout_try/try_page.js'),
		'utf8'
	);
	assert.equal((page.match(/\.innerHTML\s*=/g) || []).length, 1, 'only the fixed markup is parsed');
	assert.ok(page.includes('root.innerHTML = MARKUP;'), 'the one HTML write is the page markup');
	assert.ok(page.includes('area.setRangeText(result.text'), 'typed text enters the field as text');
}

const controls = {
	layout: checkLayoutDataRoutes,
	dom: checkLiteralDemo,
	try: checkTryLiteral
};
const requested = process.argv.slice(2);
const selected = requested.length ? requested : Object.keys(controls);
assert.ok(
	selected.length > 0 && selected.every((name) => Object.hasOwn(controls, name)),
	'only nonempty registered text controls may be selected'
);
async function main() {
	for (const name of selected) await controls[name]();
	console.log(`PASS ${selected.length} web text controls: ${selected.join(', ')}.`);
}
main().catch((error) => {
	console.error(error);
	process.exitCode = 1;
});
