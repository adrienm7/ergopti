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
const start = keyboard.indexOf('function unescapeTomlString(');
const end = keyboard.indexOf('\nif (typeof window', start);
assert.ok(start >= 0 && end > start, 'the actual TOML decoding and parsing owners are present');
const context = vm.createContext({});
vm.runInContext(keyboard.slice(start, end), context);

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
}

async function checkHotstringSources() {
	const urlOwner = fs.readFileSync(path.join(root, 'src/lib/js/hotstringDataUrls.js'), 'utf8');
	const catalogue = '/ergopti_plus/_shared/modules/hotstrings';
	const page = fs.readFileSync(
		path.join(root, 'src/routes/utilisation/introduction_telechargements.svelte'),
		'utf8'
	);
	const script = page.slice(page.indexOf('<script>') + 8, page.indexOf('</script>'));
	const keyboardProgram = parse(keyboard, { ecmaVersion: 'latest', sourceType: 'module' });
	const browserLoads = keyboardProgram.body.filter((node) => node.type === 'IfStatement');
	assert.equal(browserLoads.length, 1, 'execute the one actual keyboard browser load');
	const browserLoad = browserLoads[0];
	assert.equal(
		browserLoad.consequent.body.length,
		1,
		'the actual keyboard load is one promise chain'
	);
	assert.equal(browserLoad.consequent.body[0].type, 'ExpressionStatement');
	const keyboardDeclarations = keyboardProgram.body
		.filter((node) => node.type !== 'ImportDeclaration' && node.end <= browserLoad.start)
		.map((node) => keyboard.slice(node.start, node.end))
		.join('\n');
	const keyboardLoad = keyboard.slice(
		browserLoad.consequent.body[0].expression.start,
		browserLoad.consequent.body[0].expression.end
	);
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
			return Promise.resolve({ text: async () => text });
		}
		const keyboardContext = vm.createContext({ base, window: {}, fetch: fetchStatic });
		vm.runInContext(urlOwner.replace(/^export /gm, ''), keyboardContext);
		vm.runInContext(keyboardDeclarations, keyboardContext);
		await vm.runInContext(keyboardLoad, keyboardContext);
		const loadedMagic = vm.runInContext('magic', keyboardContext);
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

function checkLiteralDemo() {
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

const controls = {
	decode: checkDecoding,
	simple: () => checkQuotedParsing(`plain = "${'\\!'.repeat(65536)}`),
	object: () => checkQuotedParsing(`"object" = { output = "${'\\!'.repeat(65536)} }`),
	dom: checkLiteralDemo
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
