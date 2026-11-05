'use strict';
const fs = require('node:fs'),
	path = require('node:path'),
	assert = require('node:assert/strict'),
	vm = require('node:vm');
const root = path.resolve(process.argv[2] || process.env.SOURCE_ROOT || '.');
const file = path.join(root, 'static/ergopti_plus/windows/ui/personal_toml_editor_webview.ahk');
const src = fs.readFileSync(file, 'utf8');
const body = src.match(/_HsEdWeb_ShowSaveFailure\(\) \{([\s\S]*?)\n\}/)?.[1];
assert(body, 'actual function exists');
assert(
	src.includes('_HsEdWeb_JsStr(s) {\n\treturn JsonStringLiteral(s)'),
	'real string adapter must return complete JSON literal'
);
const expr = body
	.slice(body.indexOf('_HsEdWeb_Eval(') + '_HsEdWeb_Eval('.length)
	.trim()
	.replace(/\)\s*$/, '');
function emit(message) {
	const tokens = expr.match(/'(?:`.|[^'])*'|\bMessage\b|\.|\s+/g);
	assert(tokens && tokens.join('') === expr, 'entire actual AHK expression tokenized');
	return tokens
		.map((t) =>
			t === 'Message'
				? JSON.stringify(message)
				: t.startsWith("'")
					? t.slice(1, -1).replace(/`'/g, "'")
					: t.trim() === '.' || !t.trim()
						? ''
						: (() => {
								throw Error(t);
							})()
		)
		.join('');
}
const results = [];
for (const message of ['Save failed', 'Écriture impossible', 'Quote " and slash \\']) {
	const generated = emit(message);
	let failure;
	try {
		new vm.Script(generated);
	} catch (e) {
		failure = e;
	}
	assert(failure instanceof SyntaxError, 'actual emission must reproduce invalid JS');
	// Independent semantic control: insert the same complete JSON literal directly.
	const element = { textContent: 'Saved', classList: { add() {} } };
	vm.runInNewContext(
		'(function(){const e=document.getElementById("save-toast");if(e){e.textContent=' +
			JSON.stringify(message) +
			';e.classList.add("show");}})();',
		{ document: { getElementById: () => element } }
	);
	assert.equal(element.textContent, message);
	results.push({ message, generated, error: failure.message, control: element.textContent });
}
const shared = fs.readFileSync(
	path.join(root, 'static/ergopti_plus/_shared/ui/hotstring_editor/script.js'),
	'utf8'
);
const model = shared.slice(0, shared.indexOf('// ======= 15/ Event Wiring'));
let posts = [],
	shown = false;
const ctx = vm.createContext({
	console,
	makeHostBridge: () => () => {},
	setTimeout: () => 1,
	document: {
		getElementById: () => ({
			classList: {
				add() {
					shown = true;
				}
			}
		})
	}
});
ctx.window = ctx;
vm.runInContext(model, ctx);
ctx.post = (action, data) => posts.push({ action, data });
vm.runInContext(
	'D={sections:[{name:"personal",description:"Personal",entries:[]}]};render=()=>{};toLua=post;persist();',
	ctx
);
assert.equal(posts[0].action, 'save');
assert.equal(shown, true);
console.log(
	JSON.stringify(
		{
			sourceRoot: root,
			provenance:
				'actual AHK function expression evaluated with its real JsonStringLiteral contract; actual shared persist VM; no AHK/WebView runtime',
			results,
			persist: { posted: posts[0].action, optimisticToastShown: shown }
		},
		null,
		2
	)
);
