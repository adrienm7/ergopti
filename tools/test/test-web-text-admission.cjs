// tools/test/test-web-text-admission.cjs

/** Execute the web text owners against escapes, rejected lines and literal DOM input. */
'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const { parse } = require('acorn');
const { parse: parseToml } = require('smol-toml');

const root = path.resolve(__dirname, '../..');
const keyboard = fs.readFileSync(path.join(root, 'src/lib/keyboard/KeyboardEmulation.js'), 'utf8');
const keyboardProgram = parse(keyboard, { ecmaVersion: 'latest', sourceType: 'module' });
const parserOwners = keyboardProgram.body.filter(
	(node) =>
		node.type === 'FunctionDeclaration' &&
		['unescapeTomlString', 'parseTomlMagic'].includes(node.id.name)
);
assert.equal(parserOwners.length, 2, 'the actual TOML decoding and parsing owners are present');
const context = vm.createContext({});
vm.runInContext(
	parserOwners.map((node) => keyboard.slice(node.start, node.end)).join('\n'),
	context
);

async function checkDecoding() {
	for (const [source, expected] of [
		[String.raw`\\n`, String.raw`\n`],
		[String.raw`\\r`, String.raw`\r`],
		[String.raw`\\t`, String.raw`\t`],
		[String.raw`\\"`, '\\"'],
		[String.raw`\\'`, "\\'"],
		[String.raw`\n\r\t\"\'\\`, '\n\n\t"\'\\'],
		[String.raw`unknown\q`, String.raw`unknown\q`],
		['a\r\nb\rc', 'a\nb\nc'],
		['', '']
	]) {
		assert.equal(
			context.unescapeTomlString(source),
			expected,
			`decode source exactly once: ${JSON.stringify(source)}`
		);
	}
	assert.equal(context.unescapeTomlString(undefined), undefined);
	assert.equal(context.unescapeTomlString(null), null);
	const parsed = context.parseTomlMagic(String.raw`literal = "\\n"
"object" = { output = "a\"b\\c", label = "kept" }
[[repeat]]
ignored = "repeat"
[other]
accepted = "yes"`);
	assert.equal(parsed.literal, String.raw`\n`);
	assert.equal(parsed.object, 'a"b\\c');
	assert.equal(parsed.ignored, undefined);
	assert.equal(parsed.accepted, 'yes');
	await checkHotstringSources();
	await checkLayoutDataRoutes();
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
			base,
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

async function checkHotstringSources() {
	const urlOwner = fs.readFileSync(path.join(root, 'src/lib/js/hotstringDataUrls.js'), 'utf8');
	const catalogue = '/ergopti_plus/_shared/modules/hotstrings';
	const page = fs.readFileSync(
		path.join(root, 'src/routes/utilisation/introduction_telechargements.svelte'),
		'utf8'
	);
	const script = page.slice(page.indexOf('<script>') + 8, page.indexOf('</script>'));
	const browserLoads = keyboardProgram.body.filter((node) => node.type === 'IfStatement');
	assert.equal(browserLoads.length, 0, 'keyboard import does not start a browser load');
	const loaders = keyboardProgram.body.filter(
		(node) => node.type === 'FunctionDeclaration' && node.id.name === 'loadMagicData'
	);
	assert.equal(loaders.length, 1, 'execute the one explicit keyboard catalogue loader');
	assert.equal(loaders[0].async, true, 'the actual loader exposes its completion and failure');
	const keyboardDeclarations = keyboardProgram.body
		.filter((node) => node.type === 'FunctionDeclaration')
		.map((node) => keyboard.slice(node.start, node.end))
		.join('\n');
	const pageProgram = parse(script, { ecmaVersion: 'latest', sourceType: 'module' });
	const pageScript = pageProgram.body
		.filter((node) => node.type !== 'ImportDeclaration')
		.map((node) => script.slice(node.start, node.end))
		.join('\n');
	for (const base of ['', '/dev']) {
		const symbolsUrl = `${base}${catalogue}/magickey.toml`;
		const frenchUrl = `${base}${catalogue}/french/magickey.toml`;
		const requests = [];
		function fetchStatic(url) {
			requests.push(url);
			const pathname = url.startsWith(`${base}/`) ? url.slice(base.length) : '';
			const file = pathname ? path.join(root, 'static', pathname) : '';
			const text = file && fs.existsSync(file) ? fs.readFileSync(file, 'utf8') : '<html>404</html>';
			return Promise.resolve({
				ok: !!file && fs.existsSync(file),
				status: file && fs.existsSync(file) ? 200 : 404,
				text: async () => text
			});
		}
		const keyboardContext = vm.createContext({
			base,
			window: {},
			fetch: fetchStatic,
			AbortController
		});
		vm.runInContext(urlOwner.replace(/^export /gm, ''), keyboardContext);
		vm.runInContext(keyboardDeclarations, keyboardContext);
		assert.deepEqual(requests, [], 'declaring the actual loader performs no request');
		const loadedMagic = await vm.runInContext(
			'loadMagicData(new AbortController().signal)',
			keyboardContext
		);
		for (const [key, expected] of [
			['c', 'c’est'],
			['gt', 'j’étais'],
			['pex', 'par exemple'],
			['(v)', '✓'],
			['-->', ' ➜ '],
			['dec', 'décembre'],
			['déc', 'décembre']
		]) {
			assert.equal(
				loadedMagic[key],
				expected,
				`the actual keyboard retains ${key} from its source`
			);
		}
		assert.deepEqual(
			requests,
			[symbolsUrl, frenchUrl],
			'keyboard fetches both real base-aware sources'
		);
		requests.length = 0;
		const mounts = [],
			errors = [];
		const pageContext = vm.createContext({
			parseToml,
			base,
			window: {},
			fetch: fetchStatic,
			onMount: (callback) => mounts.push(callback),
			console: { error: (...values) => errors.push(values) },
			magicSampleToml: fs.readFileSync(
				path.join(root, 'src/routes/utilisation/magic_sample.toml'),
				'utf8'
			)
		});
		vm.runInContext(urlOwner.replace(/^export /gm, ''), pageContext);
		vm.runInContext(pageScript, pageContext);
		assert.equal(mounts.length, 1, 'execute the actual section-viewer mount');
		await mounts[0]();
		assert.deepEqual(errors, [], 'real static data loads without the viewer error path');
		const sections = vm.runInContext('orderedSections', pageContext);
		assert.equal(sections[0].name, '__sample', 'the authored sample stays first');
		for (const [section, key, expected] of [
			['text_expansion', 'c★', 'c’est'],
			['text_expansion', 'gt★', 'j’étais'],
			['text_expansion', 'pex★', 'par exemple'],
			['text_expansion_symbols', '(v)★', '✓'],
			['text_expansion_symbols', '-->★', '➜'],
			['text_expansion', 'dec★', 'décembre'],
			['text_expansion', 'déc★', 'décembre']
		]) {
			assert.equal(
				sections.find((value) => value.name === section)?.entries.find((entry) => entry.key === key)
					?.output,
				expected,
				`the actual viewer retains ${section}/${key}`
			);
		}
		const expectedTitles = [
			['text_expansion_symbols', 'Expansion de texte Symboles : -->★ = ➜, (v)★ = ✓, …'],
			[
				'text_expansion_symbols_typst',
				'Expansion de texte Symboles Typst : $eq.not$ = ≠, $PP$ = ℙ, $integral$ = ∫ …'
			],
			['text_expansion', 'Expansion de texte : c★ = c’est, gt★ = j’étais, pex★ = par exemple, …'],
			[
				'text_expansion_auto',
				"Expansion de texte automatique (sans la touche ★) : ju' = jusqu’, ya = y’a"
			],
			['text_expansion_emojis', 'Expansion de texte Emojis : voiture★ = 🚗, koala★ = 🐨, …']
		];
		for (const [name, expected] of expectedTitles) {
			assert.equal(
				sections.find((section) => section.name === name)?.title,
				expected,
				`the actual viewer uses the authored French title for ${name}`
			);
		}
		assert.equal(sections.length, 6, 'the sample and all five actual catalogue sections remain');
		pageContext.titleDocument = `[_meta]
sections_order = ["legacy"]
[_meta.sections]
legacy = "Legacy section title"
[[legacy]]
"x★" = { output = "value" }`;
		assert.equal(
			vm.runInContext('parseTomlSections(titleDocument).meta.sections.legacy', pageContext),
			'Legacy section title',
			'actual metadata parsing retains authored scalar string titles'
		);
		for (const metadata of [
			'[_meta.sections]\nlegacy = { en = "English without French" }',
			'[_meta.sections]\nlegacy = 3',
			'[_meta.sections]\nlegacy = { fr = 3 }',
			'[_meta.sections]\nlegacy = { fr = "" }',
			'[_meta.sections]\nlegacy = { fr = "French", en = 3 }',
			'[_meta.sections]\nunknown = { fr = "Unknown section" }',
			'[_meta]\nsections = 3',
			'[_meta]\nsections_order = "legacy"',
			'_meta = 3',
			'[_meta.sections]\nlegacy = { fr = '
		]) {
			pageContext.titleDocument = metadata + '\n[[legacy]]\n"x★" = { output = "value" }';
			assert.throws(
				() => vm.runInContext('parseTomlSections(titleDocument)', pageContext),
				'malformed or unknown title metadata must refuse rather than render/fallback'
			);
		}
		const simpleFrench = vm.runInContext('remplacements', pageContext);
		for (const [key, expected] of [
			['c★', 'c’est'],
			['gt★', 'j’étais'],
			['pex★', 'par exemple']
		]) {
			assert.equal(simpleFrench[key], expected, `the separate French map retains ${key}`);
		}
		assert.deepEqual(
			requests,
			[frenchUrl, symbolsUrl, frenchUrl],
			'page retains French map and both catalogues'
		);
	}
	for (const program of [keyboardProgram, pageProgram]) {
		assert.ok(
			program.body.some(
				(node) =>
					node.type === 'ImportDeclaration' && node.source.value === '$lib/js/hotstringDataUrls.js'
			),
			'the actual consumer imports the shared URL owner'
		);
	}
}

function checkQuotedParsing(line) {
	context.input = line;
	const refused = vm.runInContext('parseTomlMagic(input)', context, {
		timeout: 1000
	});
	assert.equal(
		Object.keys(refused).length,
		0,
		'unterminated quoted input is refused within a finite parser budget'
	);
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

/** Compile the actual class and base owner with finite stores, DOM and request ports. */
function emulationRealm(fetchPort, base = '') {
	const baseSource = fs.readFileSync(path.join(root, 'src/lib/keyboard/Keyboard.js'), 'utf8');
	const baseOwner = parse(baseSource, { ecmaVersion: 'latest', sourceType: 'module' }).body.find(
		(node) => node.type === 'ExportNamedDeclaration' && node.declaration?.id?.name === 'Keyboard'
	);
	assert.ok(baseOwner, 'the actual inherited lifecycle owner is present');
	const requests = [],
		errors = [],
		listeners = new Set();
	const observations = { lookups: 0, renders: 0, available: true };
	const textarea = { value: 'c', selectionStart: 1, setSelectionRange() {} };
	const store = (value) => ({
		value,
		subscribe(callback) {
			const subscription = () => callback();
			listeners.add(subscription);
			callback();
			return () => listeners.delete(subscription);
		}
	});
	const realm = vm.createContext({
		base,
		window: {},
		AbortController,
		get: (value) => value.value,
		stores_infos: {
			layoutData: store({ fixture: [], keys: [] }),
			emulation: store({ plus: 'no', type: 'fixture' }),
			other: store({ plus: 'no', type: 'fixture' })
		},
		fetch(url, options) {
			requests.push({ url, options });
			return fetchPort(url, options, requests.length - 1);
		},
		console: { info() {}, error: (...values) => errors.push(values) },
		document: {
			getElementById(id) {
				observations.lookups += 1;
				return id === 'input-text' ? textarea : observations.available ? {} : null;
			}
		}
	});
	const urls = fs.readFileSync(path.join(root, 'src/lib/js/hotstringDataUrls.js'), 'utf8');
	vm.runInContext(urls.replace(/^export /gm, ''), realm);
	vm.runInContext(baseSource.slice(baseOwner.declaration.start, baseOwner.declaration.end), realm);
	const executable = keyboardProgram.body
		.filter((node) => node.type !== 'ImportDeclaration')
		.map((node) => {
			const declaration = node.type === 'ExportNamedDeclaration' ? node.declaration : node;
			return keyboard.slice(declaration.start, declaration.end);
		})
		.join('\n');
	vm.runInContext(executable + '\nthis.Subject = KeyboardEmulation;', realm);
	assert.equal(requests.length, 0, 'evaluating the complete keyboard module performs zero fetches');
	for (const name of ['updateKeys', 'updateKeyboardConfiguration', 'pressCurrentLayerModifiers'])
		realm.Subject.prototype[name] = () => observations.renders++;
	return { realm, requests, errors, listeners, observations, textarea };
}

function deferredResponse() {
	let resolve, reject;
	const promise = new Promise((done, fail) => {
		resolve = done;
		reject = fail;
	});
	return { promise, resolve, reject };
}

function magicResponse(index) {
	return {
		ok: true,
		status: 200,
		text: async () => (index % 2 ? 'c = "c’est"\n' : 'symbol = "✓"\n')
	};
}

/** Receive actual pending, failed, successful and retired owners without network or browser work. */
async function checkEmulationLoading() {
	const pending = [deferredResponse(), deferredResponse()];
	const first = emulationRealm((_url, _options, index) => pending[index].promise, '/dev');
	const owner = new first.realm.Subject('emulation');
	owner.textarea = first.textarea;
	assert.equal(first.requests.length, 0, 'construction performs zero fetches');
	assert.equal(first.listeners.size, 0);
	assert.equal(first.observations.lookups, 0);
	assert.equal(owner.state, 'new');
	assert.throws(() => owner.mount(), /not ready/);
	const loading = owner.loadMagic();
	assert.equal(owner.magicState, 'loading');
	assert.equal(owner.magic, null);
	assert.equal(owner.state, 'new', 'pending data does not consume the base mount transition');
	assert.equal(first.listeners.size, 0);
	assert.deepEqual(
		first.requests.map((request) => request.url),
		[
			'/dev/ergopti_plus/_shared/modules/hotstrings/magickey.toml',
			'/dev/ergopti_plus/_shared/modules/hotstrings/french/magickey.toml'
		]
	);
	assert.equal(first.requests[0].options.signal, first.requests[1].options.signal);
	const forbiddenEvent = new Proxy(
		{},
		{ get: () => assert.fail('pending or retired emulation must not inspect a key event') }
	);
	owner.emulateKey(forbiddenEvent);
	owner.releaseKey(forbiddenEvent);
	owner.sendResult('★');
	assert.equal(first.textarea.value, 'c');
	await assert.rejects(() => owner.loadMagic(), /already initialized/);
	assert.equal(
		first.requests.length,
		2,
		'duplicate initialization creates no second request owner'
	);
	pending[0].resolve(magicResponse(0));
	await Promise.resolve();
	assert.equal(owner.magic, null, 'one catalogue cannot publish partial readiness');
	owner.destroy();
	assert.equal(first.requests[0].options.signal.aborted, true);
	assert.equal(owner.magicState, 'disposed');
	pending[1].resolve(magicResponse(1));
	await assert.rejects(loading, /cancelled/);
	assert.equal(owner.magic, null, 'late completion cannot publish into a retired owner');
	assert.equal(first.listeners.size, 0);
	assert.equal(first.observations.renders, 0);
	owner.emulateKey(forbiddenEvent);
	owner.releaseKey(forbiddenEvent);
	owner.sendResult('★');
	assert.throws(() => owner.mount(), /not ready/);
	assert.throws(() => owner.destroy(), /no active initialization/);

	const success = emulationRealm((_url, _options, index) => Promise.resolve(magicResponse(index)));
	const a = new success.realm.Subject('emulation');
	const b = new success.realm.Subject('other');
	a.textarea = success.textarea;
	await a.loadMagic();
	assert.equal(a.state, 'new');
	assert.equal(b.magic, null, 'another instance does not inherit a published dictionary');
	a.mount();
	assert.equal(a.magicState, 'ready');
	assert.equal(success.listeners.size, 2);
	a.sendResult('★');
	assert.equal(
		success.textarea.value,
		'c’est',
		'the actual per-instance lookup retains magic expansion'
	);
	await b.loadMagic();
	assert.notEqual(a.magic, b.magic, 'each initialization owns its complete dictionary');
	assert.equal(b.magic.c, 'c’est');
	a.magic.c = 'changed only in first owner';
	assert.equal(b.magic.c, 'c’est');
	await assert.rejects(() => a.loadMagic(), /already initialized/);
	assert.throws(() => a.mount(), /already initialized/);
	const queued = [...success.listeners];
	const rendered = success.observations.renders;
	a.destroy();
	for (const callback of queued) callback();
	assert.equal(success.observations.renders, rendered);
	assert.equal(success.listeners.size, 0);
	assert.equal(a.magic, null);
	b.destroy();

	for (const [failure, failedIndex] of ['http', 'network', 'text', 'empty', 'ignored'].flatMap(
		(failure) => [0, 1].map((index) => [failure, index])
	)) {
		const sentinel = new Error('controlled ' + failure + ' failure');
		let refusedBodyReads = 0;
		const failed = emulationRealm((_url, _options, index) => {
			if (index !== failedIndex) return Promise.resolve(magicResponse(index));
			if (failure === 'network') return Promise.reject(sentinel);
			return Promise.resolve({
				ok: failure !== 'http',
				status: failure === 'http' ? 503 : 200,
				text: async () => {
					refusedBodyReads += 1;
					if (failure === 'text') throw sentinel;
					if (failure === 'ignored') return '"ignore\\\\★" = { output = "unused" }\n';
					return '';
				}
			});
		});
		const subject = new failed.realm.Subject('emulation');
		await assert.rejects(
			() => subject.loadMagic(),
			(error) => error === sentinel || /catalogue/.test(error.message)
		);
		assert.equal(subject.magicState, 'error', failure + ' cannot become empty-data success');
		assert.equal(subject.magic, null);
		assert.equal(subject.state, 'new');
		assert.equal(failed.listeners.size, 0);
		assert.ok(failed.requests.every(({ options }) => options.signal.aborted));
		if (failure === 'http') assert.equal(refusedBodyReads, 0, 'HTTP failure body is not admitted');
		assert.throws(() => subject.mount(), /not ready/);
		subject.emulateKey(forbiddenEvent);
		subject.releaseKey(forbiddenEvent);
		subject.sendResult('★');
		subject.destroy();
	}
	await checkEmulationComponent();
}

async function checkEmulationComponent() {
	const component = fs.readFileSync(
		path.join(root, 'src/lib/keyboard/KeyboardEmulation.svelte'),
		'utf8'
	);
	const script = component.slice(component.indexOf('<script>') + 8, component.indexOf('</script>'));
	const program = parse(script, { ecmaVersion: 'latest', sourceType: 'module' });
	const executable = program.body
		.filter((node) => node.type !== 'ImportDeclaration')
		.map((node) => script.slice(node.start, node.end))
		.join('\n');
	assert.match(component, /data-emulation-state=\{readiness\}/);
	assert.match(component, /disabled=\{readiness !== 'ready'\}/);
	assert.match(component, /aria-busy=\{readiness === 'loading'\}/);
	for (const mode of ['ready', 'cancel', 'cancel-error', 'abort', 'http', 'mount-failure']) {
		const pending = [deferredResponse(), deferredResponse()];
		const ports = emulationRealm((_url, options, index) => {
			if (mode === 'abort')
				options.signal.addEventListener('abort', () =>
					pending[index].reject(new Error('controlled owned abort'))
				);
			return pending[index].promise;
		});
		const mounts = [];
		ports.realm.onMount = (callback) => mounts.push(callback);
		let loading;
		const actualLoad = ports.realm.Subject.prototype.loadMagic;
		ports.realm.Subject.prototype.loadMagic = function () {
			loading = actualLoad.call(this);
			return loading;
		};
		vm.runInContext(executable, ports.realm);
		assert.equal(
			ports.requests.length,
			0,
			'component construction leaves request ownership unstarted'
		);
		assert.equal(mounts.length, 1);
		const cleanup = mounts[0]();
		assert.equal(
			typeof cleanup,
			'function',
			'onMount returns cleanup synchronously while data waits'
		);
		assert.equal(vm.runInContext('readiness', ports.realm), 'loading');
		assert.equal(ports.listeners.size, 0);
		const cancelled = ['cancel', 'cancel-error', 'abort'].includes(mode);
		if (cancelled) cleanup();
		if (mode === 'mount-failure') ports.observations.available = false;
		if (mode === 'cancel-error') pending[0].reject(new Error('controlled late response failure'));
		else pending[0].resolve(mode === 'http' ? { ok: false, status: 503 } : magicResponse(0));
		pending[1].resolve(magicResponse(1));
		if (cancelled || mode === 'http') await assert.rejects(loading);
		else await loading;
		await Promise.resolve();
		await Promise.resolve();
		const subject = vm.runInContext('keyboard', ports.realm);
		if (mode === 'ready') {
			assert.equal(vm.runInContext('readiness', ports.realm), 'ready');
			assert.equal(ports.listeners.size, 2);
			assert.deepEqual(ports.errors, []);
		} else if (cancelled) {
			assert.equal(
				vm.runInContext('readiness', ports.realm),
				'loading',
				'late completion cannot publish'
			);
			assert.equal(subject.magicState, 'disposed');
			assert.equal(subject.magic, null);
			assert.equal(ports.listeners.size, 0);
			assert.deepEqual(ports.errors, [], 'owned cancellation does not become an active load error');
			assert.ok(ports.requests.every(({ options }) => options.signal.aborted));
		} else {
			assert.equal(vm.runInContext('readiness', ports.realm), 'error');
			assert.equal(ports.listeners.size, 0);
			assert.ok(
				ports.errors.some(([message]) => message === '[KeyboardEmulation] Initialization failed'),
				'active HTTP and mount failures remain observable'
			);
		}
		if (!cancelled) cleanup();
		assert.equal(ports.listeners.size, 0);
		assert.equal(subject.magicState, 'disposed');
	}
}

const controls = {
	decode: checkDecoding,
	simple: () => checkQuotedParsing(`plain = "${'\\!'.repeat(65536)}`),
	object: () => checkQuotedParsing(`"object" = { output = "${'\\!'.repeat(65536)} }`),
	dom: checkLiteralDemo,
	emulation: checkEmulationLoading
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
