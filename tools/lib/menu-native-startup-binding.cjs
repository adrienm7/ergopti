'use strict';

// SOURCE-ONLY CANDIDATE, UNRUN. A finite physical startup route contract.
// Not a general AHK flow analyzer, runtime admission, or whole-policy exemption.
const { isDeepStrictEqual } = require('node:util');
const { scriptTokens, stripComments } = require('./script-source.cjs');
const projection = require('./codegen-startup-tray.cjs');
const keys = Object.freeze({
	entry: 'windows/ErgoptiPlus.ahk',
	bootstrap: 'windows/infra/tray_bootstrap.ahk',
	dispatcher: 'windows/infra/menu_dispatcher.ahk',
	safe: 'windows/infra/menu_startup_commands.ahk'
});
function tokensOf(source) {
	const tokens = scriptTokens(source, '.ahk');
	for (let i = 0; i < tokens.length; i++)
		tokens[i].lineBefore = i > 0 && /\n/.test(source.slice(tokens[i - 1].end, tokens[i].start));
	return tokens;
}
function lex(source) {
	if (typeof source !== 'string' || !source) return null;
	const tokens = tokensOf(source),
		depth = [],
		closes = new Map(),
		stack = [];
	for (let i = 0; i < tokens.length; i++) {
		depth[i] = stack.length;
		if (tokens[i].kind === 'symbol' && tokens[i].value === '{') stack.push(i);
		else if (tokens[i].kind === 'symbol' && tokens[i].value === '}') {
			const open = stack.pop();
			if (open === undefined) return null;
			closes.set(open, i);
		}
	}
	return stack.length ? null : { tokens, depth, closes };
}
function equalTokens(actual, expected) {
	return (
		actual.length === expected.length &&
		actual.every(
			(token, i) =>
				token.kind === expected[i].kind &&
				token.value === expected[i].value &&
				(i === 0 || token.lineBefore === expected[i].lineBefore)
		)
	);
}
function matches(unit, statement, depth) {
	if (!unit) return [];
	const wanted = tokensOf(statement),
		found = [];
	for (let i = 0; i <= unit.tokens.length - wanted.length; i++) {
		if (depth !== undefined && unit.depth[i] !== depth) continue;
		if (['.', ':'].includes(unit.tokens[i - 1]?.value)) continue;
		if (equalTokens(unit.tokens.slice(i, i + wanted.length), wanted)) found.push(i);
	}
	return found;
}
function body(source, signature) {
	const unit = lex(source),
		found = matches(unit, signature, 0);
	if (found.length !== 1) return null;
	const start = found[0],
		size = scriptTokens(signature, '.ahk').length;
	const open = start + size - 1;
	if (unit.tokens[open]?.value !== '{' || !unit.closes.has(open)) return null;
	return unit.tokens.slice(open + 1, unit.closes.get(open));
}
function exactBody(source, signature, contract) {
	const actual = body(source, signature);
	return actual !== null && equalTokens(actual, tokensOf(contract));
}
function sourceInclude(source, path) {
	// The native include is a directive, not text inside a quote/comment.
	const unit = lex(source),
		found = matches(unit, '#Include ' + path, 0);
	return (
		found.length === 1 &&
		stripComments(source, '.ahk').slice(unit.tokens[found[0]].start).split('\n', 1)[0].trim() ===
			'#Include ' + path
	);
}
function changedSymbol(unit, name) {
	return unit.tokens.some(
		(token, i) =>
			token.kind === 'identifier' &&
			token.value === name &&
			[':=', '=', '+', '-'].includes(unit.tokens[i + 1]?.value)
	);
}

// Independent, hand-authored finite statement contracts. Complete bodies are
// checked, so dead branches, shadowing, extra returns, intervening writes and
// native/foreign result substitution do not satisfy a collection of needles.
// These contracts are deliberately bounded to existing startup ABI, not a
// generated source oracle or an exemption for any file containing a helper.
const commandPublication = `
  if !HasMethod(RequestFn, "Call")
    throw TypeError("Native startup tray requires a command owner")
  if !IsObject(MenuObj)
    MenuObj := A_TrayMenu
  Register := HasMethod(RegisterFn, "Call") ? RegisterFn : RegisterMenuItem
  Commands := Map(
    "suspend", MenuStartupSafeCommand(RequestFn.Bind("suspend")),
    "reload", MenuStartupSafeCommand(RequestFn.Bind("reload")),
    "quit", MenuStartupSafeCommand(RequestFn.Bind("quit")))
  Rows := _TrayBootstrapProjectedRows("commands", Commands)
  PreviousCritical := Critical("On")
  try {
    MenuDispatcher_BeginReplacement()
    MenuObj.Delete()
    for Row in Rows {
      if Register.Call(MenuObj, Row.Label, Row.Callback) != 1
        throw Error("Native startup command registration failed: " . Row.Id)
    }
    if !HasMethod(RegisterFn, "Call")
      MenuDispatcher_PruneMenu(MenuObj)
    return true
  } finally Critical(PreviousCritical)
`;
const inertPublication = `
  Status := _TrayBootstrapProjectedRows("inert", Map())[1]
  if !IsSet(Label)
    Label := Status.Label
  if !(Label is String) or Label == ""
    throw ValueError("tray bootstrap label must be a non-empty string")
  if !IsObject(MenuObj)
    MenuObj := A_TrayMenu
  PreviousCritical := Critical("On")
  try {
    MenuObj.Delete()
    MenuObj.Add(Label, _TrayBootstrapNoOp)
    MenuObj.Disable(Label)
    return true
  } finally Critical(PreviousCritical)
`;
const typedProjection = String.raw`
  global _I18nLocale
  Authority := SharedStartupTrayProjection(_I18nLocale)
  if !(Authority is Map) || Authority.Count != 5
    || Authority.Get("authority", "") != "compiled-startup"
    || !RegExMatch(Authority.Get("source_sha256", ""), "^[0-9a-f]{64}$")
    || Type(Authority.Get("locale", 0)) != "String"
    || !(Commands is Map) || !Authority.Has(Surface)
    throw Error("Immutable shared startup authority is unavailable")
  Source := Authority[Surface]
  CommandSurface := Surface == "commands"
  if (!CommandSurface && Surface != "inert") || !(Source is Array)
    || Source.Length != (CommandSurface ? Commands.Count : 1)
    throw Error("The complete shared startup surface is unavailable")
  Prepared := [], SeenIds := Map(), SeenCommands := Map(), SeenLabels := Map()
  for Row in Source {
    if !(Row is Map) || Row.Count != 6
      || Row.Get("type", "") != (CommandSurface ? "command" : "label")
      || Type(Row.Get("id", 0)) != "String" || Row["id"] == ""
      || SeenIds.Has(Row["id"])
      || Type(Row.Get("label", 0)) != "String" || Row["label"] == ""
      || RegExMatch(Row["label"], "[\x00-\x1f\x7f]") || SeenLabels.Has(Row["label"])
      || Type(Row.Get("section", 0)) != "String" || Row["section"] == ""
      || Type(Row.Get("source_id", 0)) != "String" || Row["source_id"] == ""
      throw Error("Invalid immutable startup record")
    SeenIds[Row["id"]] := true, SeenLabels[Row["label"]] := true
    if CommandSurface {
      CommandId := Row.Get("command", "")
      if Type(CommandId) != "String" || !Commands.Has(CommandId)
        || SeenCommands.Has(CommandId) || !(Commands[CommandId] is MenuStartupSafeCommand)
        throw Error("Shared startup command has no unique native capability owner")
      SeenCommands[CommandId] := true
      Prepared.Push({Id: CommandId, Label: Row["label"], Callback: Commands[CommandId]})
    } else {
      if Row.Get("command", 0) != ""
        throw Error("An inert startup record cannot acquire command authority")
      Prepared.Push({Label: Row["label"]})
    }
  }
  return Prepared
`;
const safeClass = `
  __New(Callback) {
    if !HasMethod(Callback, "Call")
      throw TypeError("Startup-safe menu commands must be callable")
    this.Callback := Callback
  }
  Call(Args*) {
    return this.Callback.Call(Args*)
  }
`;
const coldEntry = `
  #Include infra/tray_bootstrap.ahk
  #Include adapters/tray_startup_click.ahk
  #Include adapters/tray_startup_commands.ahk
  _InstallSafeBootstrapTray()
  global _TrayStartupCommands := TrayStartupCommands(
    () => IsSet(_DriverReady) && _DriverReady, TrayStartupCommand)
  if FileExist(ConfigurationFile)
    _InstallNativeStartupTray(ObjBindMethod(_TrayStartupCommands, "Request"))
`;

/**
 * Checks the genuine ESM import, canonical input readers, real callee and output
 * owner through Acorn's existing repository dependency. Quotes/comments never
 * become AST statements. Unsupported syntax/data transport is refused.
 */
function generatorHook(source) {
	if (typeof source !== 'string') return false;
	const parse = require('acorn').parse;
	const parseModule = (value) => parse(value, { ecmaVersion: 'latest', sourceType: 'module' });
	let program;
	try {
		program = parseModule(source);
	} catch {
		return false;
	}
	function shape(node) {
		if (Array.isArray(node)) return node.map(shape);
		if (!node || typeof node !== 'object') return node;
		return Object.fromEntries(
			Object.entries(node)
				.filter(([key]) => !['start', 'end', 'loc', 'raw'].includes(key))
				.map(([key, value]) => [key, shape(value)])
		);
	}
	const statements = (value) => shape(parseModule(value).body);
	const one = (wanted) => {
		const expected = statements(wanted);
		return (
			expected.length === 1 &&
			program.body.filter((node) => isDeepStrictEqual(shape(node), expected[0])).length === 1
		);
	};
	if (
		!one("import { parse as parseToml } from 'smol-toml';") ||
		!one("import { readFileSync, writeFileSync } from 'fs';") ||
		!one("import sharedPaths from '../lib/paths.cjs';") ||
		!one("import startupProjection from '../lib/codegen-startup-tray.cjs';") ||
		!one('const { shared } = sharedPaths;') ||
		!one("const MANIFEST_PATH = shared('modules/features/manifest.toml');") ||
		!one("const OUT_PATH = shared('modules/menu/menu_manifest.json');")
	)
		return false;
	const owners = program.body.filter(
		(node) => node.type === 'FunctionDeclaration' && node.id?.name === 'build'
	);
	if (owners.length !== 1 || owners[0].params.length || owners[0].async || owners[0].generator)
		return false;
	const expected = statements(`
    const raw = readFileSync(MANIFEST_PATH, 'utf8');
    const parsed = parseToml(raw);
    if (!parsed.menu || typeof parsed.menu !== 'object') {
      throw new Error('manifest.toml is missing the [menu] tables — cannot emit menu_manifest.json');
    }
    projectChoices(parsed.menu, raw);
    validateGreyedRows(parsed.menu);
    validateChildTemplates(parsed.menu);
    validateProviderStatus(parsed.menu);
    const startupPolicy = parseToml(readFileSync(shared('modules/menu/startup_tray.toml'), 'utf8'));
    const startupCodes = JSON.parse(readFileSync(shared('data/locale_order.json'), 'utf8')).order;
    const startupLocales = Object.fromEntries(startupCodes.map((code) => [
      code, JSON.parse(readFileSync(shared(\`data/locales/\${code}.json\`), 'utf8'))
    ]));
    const startupAhk = startupProjection.render(parsed.menu, startupPolicy, startupLocales);
    const out = { ...HEADER, ...parsed.menu };
    const json = JSON.stringify(out, null, '\\t') + '\\n';
    writeFileSync(OUT_PATH, json, 'utf8');
    writeFileSync(shared('modules/menu/startup_tray_projection.ahk'), startupAhk, 'utf8');
  `);
	const actual = shape(owners[0].body.body);
	// One existing informational console.log remains after all owned writes.
	if (
		actual.length !== expected.length + 1 ||
		!isDeepStrictEqual(actual.slice(0, expected.length), expected)
	)
		return false;
	const log = actual.at(-1);
	if (
		log.type !== 'ExpressionStatement' ||
		log.expression.type !== 'CallExpression' ||
		log.expression.callee.type !== 'MemberExpression' ||
		log.expression.callee.computed ||
		log.expression.callee.object.name !== 'console' ||
		log.expression.callee.property.name !== 'log' ||
		log.expression.arguments.length !== 1 ||
		log.expression.arguments[0].type !== 'TemplateLiteral'
	)
		return false;
	if (!one('build();') || !isDeepStrictEqual(shape(program.body.at(-1)), statements('build();')[0]))
		return false;
	// The informational log is not permission for executable side effects in its
	// interpolation. Preserve its actual length-only diagnostic expression.
	const canonicalLog = statements(
		'console.log(`build-menu-manifest: wrote ${OUT_PATH} (${Object.keys(parsed.menu).length} top-level keys).`);'
	)[0];
	if (!isDeepStrictEqual(log, canonicalLog)) return false;
	const protectedNames = new Set([
		'startupProjection',
		'parseToml',
		'readFileSync',
		'writeFileSync',
		'sharedPaths',
		'shared',
		'MANIFEST_PATH',
		'OUT_PATH',
		'build'
	]);
	let changed = false;
	const rootName = (node) =>
		node?.type === 'Identifier'
			? node.name
			: node?.type === 'MemberExpression'
				? rootName(node.object)
				: undefined;
	function inspect(node) {
		if (!node || typeof node !== 'object') return;
		if (
			['AssignmentExpression', 'UpdateExpression'].includes(node.type) &&
			protectedNames.has(rootName(node.left || node.argument))
		)
			changed = true;
		for (const value of Object.values(node)) {
			if (Array.isArray(value)) value.forEach(inspect);
			else if (value && typeof value === 'object') inspect(value);
		}
	}
	inspect(program);
	return !changed;
}

/** Copies only direct policy data, admitting the real TOML parser's null records.
 * Accessors, custom prototypes, cycles and unknown fields never gain credit.
 * Unknown fields survive the copy so the exact closed policy comparison rejects them.
 */
function policyData(value, seen = new Set()) {
	if (value === null || typeof value !== 'object') return value;
	if (seen.has(value)) throw new TypeError('Cyclic startup policy');
	const prototype = Object.getPrototypeOf(value);
	if (
		Array.isArray(value)
			? prototype !== Array.prototype
			: prototype !== Object.prototype && prototype !== null
	)
		throw new TypeError('Foreign startup policy owner');
	seen.add(value);
	const result = Array.isArray(value) ? [] : {};
	if (Array.isArray(value)) {
		const length = Object.getOwnPropertyDescriptor(value, 'length');
		if (
			!length ||
			!Object.hasOwn(length, 'value') ||
			!Number.isSafeInteger(length.value) ||
			length.value < 0
		)
			throw new TypeError('Indirect startup policy length');
		Object.defineProperty(result, 'length', { value: length.value });
	}
	for (const key of Reflect.ownKeys(value)) {
		if (Array.isArray(value) && key === 'length') continue;
		if (typeof key !== 'string') throw new TypeError('Foreign startup policy field');
		const descriptor = Object.getOwnPropertyDescriptor(value, key);
		if (!descriptor || !Object.hasOwn(descriptor, 'value') || !descriptor.enumerable)
			throw new TypeError('Indirect startup policy value');
		Object.defineProperty(result, key, {
			value: policyData(descriptor.value, seen),
			enumerable: true,
			writable: true,
			configurable: true
		});
	}
	seen.delete(value);
	return result;
}

/**
 * Returns actual canonical row identities only after all finite source edges
 * are proven. Missing generated artifacts, changed declarations or unknown
 * generator syntax are refused. Default/custom payload callers receive no
 * ownership credit beyond the exact genuine root call sites checked here.
 */
function nativeStartupRows(inputs, platform) {
	const none = () => new Set();
	if (platform !== 'ahk' || !inputs || !inputs.sources) return none();
	const { sources, manifest, policy, locales, generated, generator } = inputs;
	let directPolicy;
	try {
		directPolicy = policyData(policy);
	} catch {
		return none();
	}
	if (
		!isDeepStrictEqual(directPolicy, {
			commands: {
				rows: [
					{ section: 'tray_startup_suspend', id: 'suspend' },
					{ section: 'top_level', id: 'reload' },
					{ section: 'top_level', id: 'quit' }
				]
			},
			inert: { rows: [{ section: 'tray_startup_inert_frame', id: 'startup_inert_status' }] },
			captions: { fallback_locale: 'en' }
		})
	)
		return none();
	let commands, inert;
	try {
		commands = projection.resolveRows(manifest, policy.commands, 'command');
		projection.validateCommandCapabilities(commands);
		inert = projection.resolveRows(manifest, policy.inert, 'label');
		if (typeof generated !== 'string' || generated !== projection.render(manifest, policy, locales))
			return none();
	} catch {
		return none();
	}
	if (!generatorHook(generator)) return none();
	const bootstrap = sources[keys.bootstrap],
		entry = lex(sources[keys.entry]);
	const dispatcher = sources[keys.dispatcher],
		safe = sources[keys.safe];
	if (
		!entry ||
		!sourceInclude(bootstrap, '../../_shared/modules/menu/startup_tray_projection.ahk') ||
		!sourceInclude(sources[keys.entry], 'infra/menu_dispatcher.ahk') ||
		!sourceInclude(dispatcher, 'menu_startup_commands.ahk') ||
		matches(entry, coldEntry, 0).length !== 1 ||
		matches(entry, '_InstallSafeBootstrapTray()', 0).length !== 1 ||
		matches(entry, '_InstallNativeStartupTray(ObjBindMethod(_TrayStartupCommands, "Request"))', 0)
			.length !== 2 ||
		!exactBody(
			bootstrap,
			'_InstallNativeStartupTray(RequestFn, MenuObj := 0, RegisterFn := 0) {',
			commandPublication
		) ||
		!exactBody(
			bootstrap,
			'_InstallSafeBootstrapTray(Label := unset, MenuObj := 0) {',
			inertPublication
		) ||
		!exactBody(bootstrap, '_TrayBootstrapProjectedRows(Surface, Commands) {', typedProjection) ||
		!exactBody(bootstrap, '_TrayBootstrapNoOp(*) {', 'return 0') ||
		!exactBody(safe, 'class MenuStartupSafeCommand {', safeClass)
	)
		return none();
	for (const source of Object.values(sources)) {
		const unit = lex(source);
		if (!unit) return none();
		for (const name of [
			'SharedStartupTrayProjection',
			'_InstallNativeStartupTray',
			'_InstallSafeBootstrapTray',
			'_TrayBootstrapProjectedRows',
			'RegisterMenuItem'
		])
			if (changedSymbol(unit, name)) return none();
	}
	// Native receiver and callback wrapper transport through the genuine default
	// RegisterMenuItem callee. Full dispatcher lifecycle remains its own suite.
	const native = body(dispatcher, 'RegisterMenuItem(MenuObj, ItemName, Callback) {');
	const prefix = tokensOf(`
    global _MenuDispatchCallbacks, _MenuDispatchLastFire, _MenuDispatcherEpoch, _MenuDispatchTokens, _MenuDispatchTokenCounter
    TrackedObj := { ItemId: 0, Callback: Callback, Epoch: _MenuDispatcherEpoch, Token: 0 }
    Wrapper := (Args*) => _TrackedDispatch(TrackedObj, Args*)
    CountBefore := _MenuItemCount(MenuObj)
    try {
      MenuObj.Add(ItemName, Wrapper)
  `);
	if (!native || !equalTokens(native.slice(0, prefix.length), prefix)) return none();
	const result = new Set();
	for (const row of [...commands, ...inert]) {
		const actual = manifest[row.section].filter(
			(item) => item.id === row.sourceId && (!item.platforms || item.platforms.includes('ahk'))
		);
		if (actual.length !== 1) return none();
		result.add(actual[0]);
	}
	return result;
}
module.exports = { keys, generatorHook, nativeStartupRows };

/** Read actual production route sources, canonical policy/catalogues and output. */
function startupInputs(repositoryRoot, manifest) {
	const fs = require('node:fs'),
		path = require('node:path');
	const { parse } = require('smol-toml');
	const sp = path.join(repositoryRoot, 'static', 'ergopti_plus');
	const readShared = (name) => fs.readFileSync(path.join(sp, '_shared', name), 'utf8');
	const codes = JSON.parse(readShared('data/locale_order.json')).order;
	if (!Array.isArray(codes) || codes.length !== 21 || new Set(codes).size !== 21)
		throw new Error('Actual startup locale catalogue order is incomplete.');
	return {
		sources: Object.fromEntries(
			Object.values(keys).map((key) => [key, fs.readFileSync(path.join(sp, key), 'utf8')])
		),
		manifest,
		policy: parse(readShared('modules/menu/startup_tray.toml')),
		locales: Object.fromEntries(
			codes.map((code) => [code, JSON.parse(readShared(`data/locales/${code}.json`))])
		),
		generated: readShared('modules/menu/startup_tray_projection.ahk'),
		generator: fs.readFileSync(
			path.join(repositoryRoot, 'tools', 'build', 'build-menu-manifest.js'),
			'utf8'
		)
	};
}
module.exports.startupInputs = startupInputs;

/** A compiled section is a reader only through its complete actual native route.
 * Every row in the section must be among the closed route's retained identities.
 */
function startupReaderSections(inputs) {
	if (
		!inputs ||
		!inputs.manifest ||
		typeof inputs.manifest !== 'object' ||
		Array.isArray(inputs.manifest)
	)
		return [];
	const owned = nativeStartupRows(inputs, 'ahk');
	return Object.entries(inputs.manifest)
		.filter(
			([key, rows]) =>
				!key.startsWith('_') &&
				Array.isArray(rows) &&
				rows.length > 0 &&
				rows.every((row) => owned.has(row))
		)
		.map(([key]) => key);
}
module.exports.startupReaderSections = startupReaderSections;
