#!/usr/bin/env node
// tools/test/test-menu-provider-kind-matches-type.cjs
//
// A manifest row is routed by its `type`, and the two routes take different
// things:
//
//   `list`    -> a LIST PROVIDER, registered in R.build's 6th argument, which
//                RETURNS provider rows (label / action / checked / items).
//   `dynamic` -> a DYNAMIC HANDLER, registered in R.build's 3rd argument, which
//                APPENDS driver rows (title / fn / menu) to the list it is given.
//
// Register one where the other belongs and the renderer finds no function for
// the id, logs a single warning, and SKIPS the row. Everything else stays green:
// test-menu-action-handler-bijection.cjs greps a driver for the quoted id and
// finds it — in the table handed to the wrong parameter — so it reports the row
// as answered. A row can be declared, "answered", and absent from the menu at
// the same time.
//
// That is not hypothetical. `active_layouts` was declared `dynamic` while
// macOS's menu_keyboard_layout.lua supplied it as a list provider, and the
// keyboard-layout submenu listed no layouts for as long as both halves existed.
// This gate is what makes the next one loud.
//
// HOW IT READS THE DRIVERS: the two Lua drivers register their functions in
// named local tables (`providers`, `dyn_handlers`, `handlers`, …) and pass those
// names positionally to ManifestMenu.build. So the check is: find each build
// call, note which variable sits in the handler slot and which in the provider
// slot, then look up the ids each of those tables defines and compare with the
// manifest's declared type for the menu being built.
//
// Inline table literals at the call site are read directly. A call whose slot is
// `nil` registers nothing and is skipped.
//
// Usage: node ./tools/test/test-menu-provider-kind-matches-type.cjs

const { readFileSync, readdirSync, statSync } = require('fs');
const { join } = require('path');
const sharedPaths = require('../lib/paths.cjs');

const { shared, REPO_ROOT } = sharedPaths;

/** Absolute path of a driver's ui/ tree. */
function driverUi(platform) {
	return join(REPO_ROOT, 'static', 'ergopti_plus', platform, 'ui');
}

const MANIFEST = JSON.parse(readFileSync(shared('modules/menu/menu_manifest.json'), 'utf8'));

// Types that arrive through the handler slot (3rd argument) and through the
// provider slot (6th). `group` uses the 4th and is not compared here.
const HANDLER_TYPES = new Set(['action', 'dynamic']);
const PROVIDER_TYPES = new Set(['list']);

/** Recursively collects .lua files under a directory. */
function luaFiles(dir) {
	const out = [];
	let entries;
	try {
		entries = readdirSync(dir);
	} catch {
		return out;
	}
	for (const name of entries) {
		const full = join(dir, name);
		if (statSync(full).isDirectory()) {
			if (name === 'tests') continue;
			out.push(...luaFiles(full));
		} else if (name.endsWith('.lua')) {
			out.push(full);
		}
	}
	return out;
}

/**
 * Splits the argument list of a call, respecting nesting and strings, so an
 * inline table containing commas does not fragment into several arguments.
 * @param {string} src Full file text.
 * @param {number} open Index of the "(" that opens the call.
 * @returns {string[]|null} Raw argument texts, or null when unbalanced.
 */
function splitArgs(src, open) {
	const args = [];
	let depth = 0;
	let start = open + 1;
	let quote = null;
	for (let i = open; i < src.length; i++) {
		const c = src[i];
		if (quote) {
			if (c === '\\') i++;
			else if (c === quote) quote = null;
			continue;
		}
		if (c === '"' || c === "'") {
			quote = c;
			continue;
		}
		if (c === '(' || c === '{' || c === '[') depth++;
		else if (c === ')' || c === '}' || c === ']') {
			depth--;
			if (depth === 0) {
				args.push(src.slice(start, i));
				return args;
			}
		} else if (c === ',' && depth === 1) {
			args.push(src.slice(start, i));
			start = i + 1;
		}
	}
	return null;
}

/** Extracts the quoted keys a Lua table literal defines as functions. */
function keysOfTableText(text) {
	const ids = new Set();
	const bracket = /\[\s*"([^"]+)"\s*\]\s*=/g;
	const bare = /(?:^|[\s{,])([A-Za-z_]\w*)\s*=\s*function/g;
	let m;
	while ((m = bracket.exec(text)) !== null) ids.add(m[1]);
	while ((m = bare.exec(text)) !== null) ids.add(m[1]);
	return ids;
}

/**
 * Finds the ids registered by a named local table in a file.
 * @param {string} src File text.
 * @param {string} name Variable name.
 * @returns {Set<string>} Ids the table defines.
 */
function keysOfNamedTable(src, name) {
	const decl = new RegExp(`local\\s+${name}\\s*=\\s*\\{`);
	const m = decl.exec(src);
	const ids = new Set();
	if (m) {
		const open = src.indexOf('{', m.index);
		let depth = 0;
		for (let i = open; i < src.length; i++) {
			if (src[i] === '{') depth++;
			else if (src[i] === '}') {
				depth--;
				if (depth === 0) {
					for (const id of keysOfTableText(src.slice(open, i + 1))) ids.add(id);
					break;
				}
			}
		}
	}
	// Tables that are declared empty and filled by assignment afterwards — and
	// the reverse: a driver that moves one id from the handler table to the
	// provider table clears it with `name["id"] = nil`, and reading the literal
	// declaration alone would still see it registered where it no longer is.
	const assign = new RegExp(`${name}\\s*\\[\\s*"([^"]+)"\\s*\\]\\s*=\\s*(\\w+)`, 'g');
	let a;
	while ((a = assign.exec(src)) !== null) {
		if (a[2] === 'nil') ids.delete(a[1]);
		else ids.add(a[1]);
	}
	return ids;
}

/** Declared type of a row id inside one manifest menu. */
function declaredType(menuKey, id) {
	for (const row of MANIFEST[menuKey] || []) {
		if (row && row.id === id) return row.type;
	}
	return null;
}

const errors = [];
let callsChecked = 0;

for (const platform of ['macos', 'linux']) {
	for (const file of luaFiles(driverUi(platform))) {
		const src = readFileSync(file, 'utf8');
		const callRe = /ManifestMenu\.build\s*\(/g;
		let m;
		while ((m = callRe.exec(src)) !== null) {
			const open = src.indexOf('(', m.index);
			const args = splitArgs(src, open);
			if (!args || args.length < 3) continue;
			const keyMatch = args[0].match(/"([^"]+)"/);
			if (!keyMatch) continue;
			const menuKey = keyMatch[1];
			callsChecked++;

			const slots = [
				{ raw: args[2], kind: 'handler', allowed: HANDLER_TYPES, arg: '3rd' },
				{ raw: args[5], kind: 'provider', allowed: PROVIDER_TYPES, arg: '6th' }
			];

			for (const slot of slots) {
				if (!slot.raw) continue;
				const text = slot.raw.trim();
				if (text === 'nil' || text === '' || text === '{}') continue;
				const ids = text.startsWith('{')
					? keysOfTableText(text)
					: keysOfNamedTable(src, text.replace(/[^\w]/g, ''));
				for (const id of ids) {
					const type = declaredType(menuKey, id);
					if (type === null) continue; // Not declared here; other gates own that.
					if (slot.allowed.has(type)) continue;
					const wanted = HANDLER_TYPES.has(type) ? '3rd (handler)' : '6th (provider)';
					errors.push(
						`${platform}: '${id}' is declared type="${type}" in ${menuKey}, but ` +
							`${file.replace(/\\/g, '/').split('/ergopti_plus/')[1]} registers it in the ` +
							`${slot.arg} argument of ManifestMenu.build — it belongs in the ${wanted} one. ` +
							'The renderer routes by type, so it will find no function for this id, warn ' +
							'once, and skip the row: declared, reported as answered by the bijection ' +
							'gate, and absent from the menu.'
					);
				}
			}
		}
	}
}

if (errors.length > 0) {
	console.error('\x1b[31m[ERROR] menu rows registered in the wrong renderer slot:\x1b[0m');
	for (const e of errors) console.error('    - ' + e);
	process.exit(1);
}

console.log(
	`\x1b[32m[OK] every registered menu row matches its declared type (${callsChecked} build call(s) checked).\x1b[0m`
);
