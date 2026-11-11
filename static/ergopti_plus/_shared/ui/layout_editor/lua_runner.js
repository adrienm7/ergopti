// _shared/ui/layout_editor/lua_runner.js

/**
 * ==============================================================================
 * MODULE: Layout Editor Lua Runner
 * DESCRIPTION:
 * Runs the shared Lua export adapter (_shared/lua/layouts/source_export.lua)
 * in the page through the vendored fengari VM (vendor/fengari-web.js, Lua 5.3),
 * so the browser reads a .keylayout and converts it to XKB with the code the
 * repository tool runs under Lua 5.4 (tools/lib/layout_source_export.lua).
 *
 * FEATURES & RATIONALE:
 * 1. One module list: MODULES names every Lua module the adapter loads; the
 *    host fetches exactly those sources (`../../lua/<name>.lua`).
 * 2. Same data path as the tool: the input crosses as JSON text and the
 *    result comes back as the Lua json module's encoding.
 * 3. Fail fast: a module that does not compile, or a Lua error, throws with
 *    the Lua message; an adapter refusal is the result's `ok = false`.
 * ==============================================================================
 */

var LayoutLuaRunner = (function () {
	'use strict';

	// Every module source_export.lua requires, directly or not, in load order.
	const MODULES = [
		'compat.utf8',
		'json',
		'table_util',
		'layouts.keylayout',
		'layouts.xkb_converter',
		'layouts.source_export'
	];

	// Encodes the step's result with the shared json module, as the tool's adapter does.
	const ENTRY =
		'local step, text = ...\n' +
		'local Json = require("json")\n' +
		'local SourceExport = require("layouts.source_export")\n' +
		'return Json.encode(SourceExport[step](assert(Json.decode(text))))\n';

	/**
	 * The path of a module's source relative to the shared Lua root.
	 * @param {string} name - A MODULES entry.
	 * @returns {string}
	 */
	function modulePath(name) {
		return `${name.split('.').join('/')}.lua`;
	}

	/** Throws the Lua error on top of the stack when a call did not succeed. */
	function check(fengari, L, status, where) {
		if (status === fengari.lua.LUA_OK) return;
		const message = fengari.lua.lua_tojsstring(L, -1);
		fengari.lua.lua_pop(L, 1);
		throw new Error(`lua ${where}: ${message}`);
	}

	/**
	 * The fengari VM once vendor/fengari-web.js has run. Its UMD wrapper assigns
	 * to the page's CommonJS `exports` (toml_prelude.js) when there is one, else
	 * to `window.fengari`.
	 * @param {object} scope - The page's global object.
	 * @returns {object}
	 */
	function loadedVm(scope) {
		const fengari = (scope.exports && scope.exports.fengari) || scope.fengari;
		if (!fengari || !fengari.lua) throw new Error('lua vm not loaded: vendor/fengari-web.js');
		return fengari;
	}

	/**
	 * A runner over the given module sources.
	 * @param {object} fengari - The fengari-web global.
	 * @param {Object<string, string>} sources - Source text per MODULES name.
	 * @returns {{call: function(('read'|'xkb'), object): object}}
	 */
	function create(fengari, sources) {
		const { lua, lauxlib, lualib, to_luastring } = fengari;
		for (const name of MODULES)
			if (typeof sources[name] !== 'string') throw new Error(`lua module missing: ${name}`);
		const L = lauxlib.luaL_newstate();
		lualib.luaL_openlibs(L);
		lua.lua_getglobal(L, to_luastring('package'));
		lua.lua_getfield(L, -1, to_luastring('preload'));
		for (const name of MODULES) {
			check(
				fengari,
				L,
				lauxlib.luaL_loadbuffer(L, to_luastring(sources[name]), null, to_luastring(`@${name}`)),
				name
			);
			lua.lua_setfield(L, -2, to_luastring(name));
		}
		lua.lua_pop(L, 2);
		return {
			call(step, input) {
				if (step !== 'read' && step !== 'xkb') throw new Error(`lua step unknown: ${step}`);
				check(fengari, L, lauxlib.luaL_loadstring(L, to_luastring(ENTRY)), 'entry');
				lua.lua_pushstring(L, to_luastring(step));
				lua.lua_pushstring(L, to_luastring(JSON.stringify(input)));
				check(fengari, L, lua.lua_pcall(L, 2, 1, 0), step);
				const text = lua.lua_tojsstring(L, -1);
				lua.lua_pop(L, 1);
				return JSON.parse(text);
			}
		};
	}

	return { MODULES, modulePath, loadedVm, create };
})();
