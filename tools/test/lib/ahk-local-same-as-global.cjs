// tools/test/lib/ahk-local-same-as-global.cjs

/**
 * ==============================================================================
 * MODULE: AutoHotkey v2 LocalSameAsGlobal Replay
 * DESCRIPTION:
 * Replays, without AutoHotkey, the load-time rule behind #Warn
 * LocalSameAsGlobal: an undeclared local of an assume-local function or method
 * whose name is also a global (a script variable, a declared global, a
 * function, a class or a built-in function or class). AutoHotkey stops after
 * the first few such warnings per load, so a child that reaches one only shows
 * the next once it is fixed; this replay lists them all at once.
 *
 * FEATURES & RATIONALE:
 * 1. Comments, quoted strings and continuation sections are masked first, so
 *    their text never reads as code; positions and lines are kept.
 * 2. Scopes come from braces: a file, a class body, a function or method (a
 *    property getter or setter included), or a plain block.
 * 3. A local is a name a function assigns (an assignment operator, ++/--, a
 *    for-loop or catch variable, or a &VarRef) that it does not declare
 *    global, static or local, that is not a parameter, and that an enclosing
 *    function does not already own (a closure shares it). An assume-global
 *    function (a bare "global") creates no local.
 * ==============================================================================
 */

'use strict';

// AutoHotkey v2.0 built-in functions and classes: every one is a global name.
// The list is the v2 function index (docs/v2/lib/index.htm, which includes
// Edit, ListLines, KeyHistory, Reload, Pause and Suspend), the Is functions
// and the built-in classes (checked against those pages on 2026-10-28).
const BUILTINS = new Set(
	`Abs ACos ASin ATan BlockInput Buffer CallbackCreate CallbackFree CaretGetPos Ceil Chr Click ClipboardAll
ClipWait ComCall ComObjActive ComObjConnect ComObjFlags ComObjFromPtr ComObjGet ComObjQuery ComObjType
ComObjValue ComObject ComObjArray ComValue ComValueRef ControlAddItem ControlChooseIndex ControlChooseString ControlClick
ControlDeleteItem ControlFindItem ControlFocus ControlGetChecked ControlGetChoice ControlGetClassNN
ControlGetEnabled ControlGetFocus ControlGetHwnd ControlGetIndex ControlGetItems ControlGetPos ControlGetStyle
ControlGetExStyle ControlGetText ControlGetVisible ControlHide ControlHideDropDown ControlMove ControlSend
ControlSendText ControlSetChecked ControlSetEnabled ControlSetStyle ControlSetExStyle ControlSetText ControlShow
ControlShowDropDown CoordMode Cos Critical DateAdd DateDiff DetectHiddenText DetectHiddenWindows DirCopy
DirCreate DirDelete DirExist DirMove DirSelect DllCall Download DriveEject DriveGetCapacity DriveGetFileSystem
DriveGetLabel DriveGetList DriveGetSerial DriveGetSpaceFree DriveGetStatus DriveGetStatusCD DriveGetType
DriveLock DriveRetract DriveSetLabel DriveUnlock Edit EditGetCurrentCol EditGetCurrentLine EditGetLine
EditGetLineCount EditGetSelectedText EditPaste EnvGet EnvSet Exit ExitApp Exp FileAppend FileCopy
FileCreateShortcut FileDelete FileEncoding FileExist FileGetAttrib FileGetShortcut FileGetSize FileGetTime
FileGetVersion FileInstall FileMove FileOpen FileRead FileRecycle FileRecycleEmpty FileSelect FileSetAttrib
FileSetTime Float Floor Format FormatTime GetKeyName GetKeySC GetKeyState GetKeyVK GetMethod GroupActivate
GroupAdd GroupClose GroupDeactivate GuiCtrlFromHwnd GuiFromHwnd HasBase HasMethod HasProp HotIf HotIfWinActive
HotIfWinExist HotIfWinNotActive HotIfWinNotExist Hotkey Hotstring IL_Add IL_Create IL_Destroy ImageSearch
IniDelete IniRead IniWrite InputBox InputHook InstallKeybdHook InstallMouseHook InStr Integer IsAlnum IsAlpha
IsDigit IsFloat IsInteger IsLabel IsLower IsNumber IsObject IsSet IsSetRef IsSpace IsTime IsUpper IsXDigit
KeyHistory KeyWait ListHotkeys ListLines ListVars ListViewGetContent LoadPicture Log Ln LTrim Max MenuFromHandle
MenuSelect Min Mod MonitorGet MonitorGetCount MonitorGetName MonitorGetPrimary MonitorGetWorkArea MouseClick
MouseClickDrag MouseGetPos MouseMove MsgBox Number NumGet NumPut ObjAddRef ObjBindMethod ObjFromPtr
ObjFromPtrAddRef ObjGetBase ObjGetCapacity ObjHasOwnProp ObjOwnPropCount ObjOwnProps ObjPtr ObjPtrAddRef
ObjRelease ObjSetBase ObjSetCapacity OnClipboardChange OnError OnExit OnMessage Ord OutputDebug Pause
Persistent PixelGetColor PixelSearch PostMessage ProcessClose ProcessExist ProcessGetName ProcessGetParent
ProcessGetPath ProcessSetPriority ProcessWait ProcessWaitClose Random RegCreateKey RegDelete RegDeleteKey
RegExMatch RegExReplace RegRead RegWrite Reload Round RTrim Run RunAs RunWait Send SendEvent SendInput
SendLevel SendMessage SendMode SendPlay SendText SetCapsLockState SetControlDelay SetDefaultMouseSpeed
SetKeyDelay SetMouseDelay SetNumLockState SetRegView SetScrollLockState SetStoreCapsLockMode SetTimer
SetTitleMatchMode SetWinDelay SetWorkingDir Shutdown Sin Sleep Sort SoundBeep SoundGetInterface SoundGetMute
SoundGetName SoundGetVolume SoundPlay SoundSetMute SoundSetVolume SplitPath Sqrt StatusBarGetText StatusBarWait
StrCompare StrGet String StrLen StrLower StrPtr StrPut StrReplace StrSplit StrTitle StrUpper SubStr Suspend
SysGet SysGetIPAddresses Tan Thread ToolTip TraySetIcon TrayTip Trim Type VarSetStrCapacity VerCompare
WinActivate WinActivateBottom WinActive WinClose WinExist WinGetClass WinGetClientPos WinGetControls
WinGetControlsHwnd WinGetCount WinGetExStyle WinGetID WinGetIDLast WinGetList WinGetMinMax WinGetPID WinGetPos
WinGetProcessName WinGetProcessPath WinGetStyle WinGetText WinGetTitle WinGetTransColor WinGetTransparent
WinHide WinKill WinMaximize WinMinimize WinMinimizeAll WinMinimizeAllUndo WinMove WinMoveBottom WinMoveTop
WinRedraw WinRestore WinSetAlwaysOnTop WinSetEnabled WinSetExStyle WinSetRegion WinSetStyle WinSetTitle
WinSetTransColor WinSetTransparent WinShow WinWait WinWaitActive WinWaitClose WinWaitNotActive
Any Object Array Class Error MemoryError OSError TargetError TimeoutError TypeError UnsetError MemberError
PropertyError MethodError UnsetItemError ValueError IndexError ZeroDivisionError File Func BoundFunc Closure
Enumerator Gui Map Menu MenuBar Primitive RegExMatchInfo VarRef`.split(/\s+/)
);

// Words that open a block like a function header would, but are statements.
const STATEMENTS = new Set(
	'if else while for loop switch case catch try finally until return throw goto break continue static global local class not and or is in contains'.split(
		' '
	)
);

/**
 * Masks comments, quoted strings and continuation sections with spaces.
 * Newlines are kept, so offsets and line numbers still match the source.
 * @param {string} source AutoHotkey v2 source.
 * @returns {string} Same length, code only.
 */
function mask(source) {
	const out = source.split('');
	const blank = (from, to) => {
		for (let i = from; i < to; i++) if (out[i] !== '\n' && out[i] !== '\r') out[i] = ' ';
	};
	const lines = source.split('\n');
	let offset = 0;
	let inBlock = false;
	let inSection = false;
	for (const line of lines) {
		const start = offset;
		offset += line.length + 1;
		if (inBlock) {
			blank(start, start + line.length);
			if (/\*\/\s*\r?$/.test(line) || /^\s*\*\//.test(line)) inBlock = false;
			continue;
		}
		if (inSection) {
			// The closing ")" line may carry code after it: keep that part.
			const close = /^(\s*\))/.exec(line);
			if (close) {
				inSection = false;
				blank(start, start + close[1].length - 1);
				continue;
			}
			blank(start, start + line.length);
			continue;
		}
		if (/^\s*\/\*/.test(line)) {
			blank(start, start + line.length);
			if (!/\*\/\s*\r?$/.test(line)) inBlock = true;
			continue;
		}
		if (/^\s*\((?:\s*(?:Join\S*|LTrim0?|RTrim0?|Comments|Com|C|`)\s*)*\r?$/i.test(line)) {
			inSection = true;
			blank(start, start + line.length);
			continue;
		}
		// Strings and line comments, left to right.
		let quote = null;
		for (let i = 0; i < line.length; i++) {
			const ch = line[i];
			if (quote) {
				if (ch === '`') {
					// An escape and the character it escapes are both string text.
					out[start + i] = ' ';
					if (i + 1 < line.length) out[start + i + 1] = ' ';
					i++;
					continue;
				}
				if (ch === quote) quote = null;
				else out[start + i] = ' ';
				continue;
			}
			if (ch === '"' || ch === "'") {
				quote = ch;
				continue;
			}
			if (ch === ';' && (i === 0 || /\s/.test(line[i - 1]))) {
				blank(start + i, start + line.length);
				break;
			}
		}
	}
	return out.join('');
}

/**
 * Returns the offset of the brace closing the one at `open`, or -1.
 * @param {string} code Masked source.
 * @param {number} open Offset of "{".
 * @returns {number}
 */
function matchBrace(code, open) {
	let depth = 0;
	for (let i = open; i < code.length; i++) {
		if (code[i] === '{') depth++;
		else if (code[i] === '}') {
			depth--;
			if (depth === 0) return i;
		}
	}
	return -1;
}

/**
 * Splits a parameter list into names.
 * @param {string} list Text between the parentheses.
 * @returns {string[]}
 */
function parameterNames(list) {
	const names = [];
	let depth = 0;
	let current = '';
	for (const ch of list + ',') {
		if (ch === '(' || ch === '[' || ch === '{') depth++;
		else if (ch === ')' || ch === ']' || ch === '}') depth--;
		if (ch === ',' && depth === 0) {
			const match = /^\s*&?\s*([A-Za-z_]\w*)/.exec(current);
			if (match) names.push(match[1]);
			current = '';
		} else current += ch;
	}
	return names;
}

/**
 * Finds the definitions opening at the outermost level of `code[from, to)`.
 * @param {string} code Masked source.
 * @param {number} from Start offset.
 * @param {number} to End offset.
 * @param {boolean} inClass Whether this range is a class body.
 * @returns {Array<object>} { kind, name, params, open, close, header }
 */
function definitions(code, from, to, inClass) {
	const found = [];
	let i = from;
	while (i < to) {
		const brace = code.indexOf('{', i);
		if (brace === -1 || brace >= to) break;
		const close = matchBrace(code, brace);
		if (close === -1) break;
		// The header is the text since the previous statement boundary; a
		// parameter list may span lines, so a ")" before the brace is matched
		// back to its "(" and the header starts on that line.
		let lineStart = code.lastIndexOf('\n', brace - 1) + 1;
		let header = code.slice(lineStart, brace);
		if (/^\s*$/.test(header)) {
			const previousEnd = lineStart - 1;
			const previousStart = code.lastIndexOf('\n', previousEnd - 1) + 1;
			header = code.slice(previousStart, previousEnd);
			lineStart = previousStart;
		}
		let back = brace - 1;
		while (back > from && /\s/.test(code[back])) back--;
		if (code[back] === ')') {
			let depth = 0;
			let paren = back;
			for (; paren >= from; paren--) {
				if (code[paren] === ')') depth++;
				else if (code[paren] === '(') {
					depth--;
					if (depth === 0) break;
				}
			}
			if (paren >= from) {
				const start = code.lastIndexOf('\n', paren - 1) + 1;
				if (start < lineStart) {
					lineStart = start;
					header = code.slice(start, brace);
				}
			}
		}
		const klass = /^\s*class\s+([A-Za-z_]\w*)/i.exec(header);
		const fn = /^\s*(?:static\s+)?([A-Za-z_][\w]*)\s*\(([\s\S]*)\)\s*$/.exec(header);
		const accessor = inClass ? null : /^\s*(get|set)\s*$/i.exec(header);
		// A braced hotkey or hotstring body is a function of ThisHotkey.
		const hotkey = !inClass && /::\s*$/.test(header) && !/^\s*(?:case|default)\b/i.test(header);
		const property = /^\s*(?:static\s+)?([A-Za-z_]\w*)\s*(?:\[[^\]]*\])?\s*$/.exec(header);
		if (klass) found.push({ kind: 'class', name: klass[1], open: brace, close, header: lineStart });
		else if (fn && !STATEMENTS.has(fn[1].toLowerCase()))
			found.push({
				kind: 'function',
				name: fn[1],
				params: parameterNames(fn[2]),
				open: brace,
				close,
				header: lineStart
			});
		else if (hotkey)
			found.push({
				kind: 'function',
				name: 'hotkey',
				params: ['ThisHotkey'],
				open: brace,
				close,
				header: lineStart,
				anonymous: true
			});
		else if (accessor)
			found.push({
				kind: 'function',
				name: accessor[1],
				params: ['value'],
				open: brace,
				close,
				header: lineStart
			});
		else if (inClass && property && !STATEMENTS.has(property[1].toLowerCase()))
			found.push({ kind: 'property', name: property[1], open: brace, close, header: lineStart });
		else found.push({ kind: 'block', open: brace, close, header: lineStart });
		i = close + 1;
	}
	return found;
}

const ASSIGNED = [
	/(?<![\w.\]$%])([A-Za-z_]\w*)\s*(?::=|\+=|-=|\*=|\/\/=|\/=|\.=|\|=|&=|\^=|>>>=|>>=|<<=|\?\?=)/g,
	/(?<![\w.])(?:\+\+|--)([A-Za-z_]\w*)\b(?!\s*[.[(])/g,
	/(?<![\w.\]])([A-Za-z_]\w*)(?:\+\+|--)/g,
	/(?<![&\w.])&([A-Za-z_]\w*)\b(?!\s*\()/g
];

/**
 * Names a function body assigns, outside its nested function bodies.
 * @param {string} body Masked body text.
 * @returns {Map<string, number>} Name to offset of its first assignment.
 */
function assignedNames(body) {
	const names = new Map();
	// A fat-arrow parameter list (defaults included) belongs to the arrow.
	body = body.replace(
		/\(([^()]*)\)(\s*=>)/g,
		(all, list, arrow) => ' '.repeat(list.length + 2) + arrow
	);
	const note = (name, at) => {
		if (!names.has(name)) names.set(name, at);
	};
	for (const pattern of ASSIGNED) {
		pattern.lastIndex = 0;
		let match;
		while ((match = pattern.exec(body)) !== null) note(match[1], match.index);
	}
	const loops = /(?:^|[\s{])for\s+([A-Za-z_]\w*(?:\s*,\s*[A-Za-z_]\w*)*)\s+in\b/gim;
	let loop;
	while ((loop = loops.exec(body)) !== null)
		for (const name of loop[1].split(',')) note(name.trim(), loop.index);
	const catches = /(?:^|[\s}])catch\b[^\n{]*?\bas\s+([A-Za-z_]\w*)/gim;
	let caught;
	while ((caught = catches.exec(body)) !== null) note(caught[1], caught.index);
	return names;
}

// Words that script-level code uses that are not variables.
const KEYWORDS = new Set(
	`if else while for in loop return try catch as finally throw global local static and or not is contains true false
unset this super break continue switch case default until goto class extends get set files parse read reg`.split(
		/\s+/
	)
);

/**
 * Names script-level code reads or writes: every one is a global variable,
 * created at load even when it is only read.
 * @param {string} text Masked script-level text.
 * @returns {Set<string>}
 */
function referencedNames(text) {
	const found = new Set();
	for (const line of text.split('\n')) {
		// Directives and hotkey or hotstring labels name no variable.
		if (/^\s*#/.test(line) || /::/.test(line)) continue;
		// Fat-arrow parameters are the arrow's own, on the line that uses them.
		const params = new Set();
		for (const arrow of line.matchAll(/\(([^()]*)\)\s*=>|\b([A-Za-z_]\w*)\s*=>/g))
			for (const name of arrow[2] ? [arrow[2]] : parameterNames(arrow[1]))
				params.add(name.toLowerCase());
		for (const match of line.matchAll(/(?<![\w.$%#])([A-Za-z_]\w*)\b(?!\s*\()(?!\s*:(?!=))/g))
			if (!KEYWORDS.has(match[1].toLowerCase()) && !params.has(match[1].toLowerCase()))
				found.add(match[1]);
	}
	return found;
}

/**
 * Names a body declares with global, static or local, and whether it is
 * assume-global.
 * @param {string} body Masked body text.
 * @returns {{ declared: Set<string>, globals: Set<string>, assumeGlobal: boolean }}
 */
function declarations(body) {
	const declared = new Set();
	const globals = new Set();
	let assumeGlobal = false;
	// A declaration continues on lines that start with a comma, or after a
	// line that ends with one.
	const lines = [];
	for (const line of body.split('\n')) {
		const last = lines.length - 1;
		if (
			last >= 0 &&
			(/^\s*,/.test(line) || /,\s*$/.test(lines[last])) &&
			/^\s*(?:global|static|local)\b/i.test(lines[last])
		)
			lines[last] += ' ' + line;
		else lines.push(line);
	}
	for (const line of lines) {
		const match = /^\s*(global|static|local)\b(.*)$/i.exec(line);
		if (!match) continue;
		const rest = match[2].trim();
		if (rest === '' && match[1].toLowerCase() === 'global') {
			assumeGlobal = true;
			continue;
		}
		// Declared names are the identifiers at list level, not inside initialisers.
		// An initialiser may open a bracket the line does not close.
		let depth = 0;
		let segment = '';
		const chars = [...rest];
		for (let k = 0; k <= chars.length; k++) {
			const ch = k === chars.length ? ',' : chars[k];
			if ('([{'.includes(ch)) depth++;
			else if (')]}'.includes(ch)) depth--;
			if (ch === ',' && (depth === 0 || k === chars.length)) {
				const name = /^\s*([A-Za-z_]\w*)/.exec(segment);
				if (name) {
					declared.add(name[1]);
					if (match[1].toLowerCase() === 'global') globals.add(name[1]);
				}
				segment = '';
			} else segment += ch;
		}
	}
	return { declared, globals, assumeGlobal };
}

/**
 * Blanks the given child ranges of a body so its own statements remain.
 * @param {string} code Masked source.
 * @param {number} from Body start.
 * @param {number} to Body end.
 * @param {Array<object>} children Nested definitions to remove.
 * @returns {string}
 */
function ownText(code, from, to, children) {
	let text = code.slice(from, to).split('');
	for (const child of children) {
		if (child.kind === 'block') continue;
		for (let i = child.header; i <= child.close; i++)
			if (i - from >= 0 && i - from < text.length && text[i - from] !== '\n') text[i - from] = ' ';
	}
	return text.join('');
}

/**
 * Finds the definitions of a range, looking through its plain blocks.
 * @param {string} code Masked source.
 * @param {number} from Start offset.
 * @param {number} to End offset.
 * @returns {Array<object>} The non-block definitions.
 */
function throughBlocks(code, from, to) {
	const nested = [];
	const collect = (items) => {
		for (const item of items) {
			if (item.kind === 'block') collect(definitions(code, item.open + 1, item.close, false));
			else nested.push(item);
		}
	};
	collect(definitions(code, from, to, false));
	return nested;
}

/**
 * Collects one file's functions (with their nesting) and its global names.
 * @param {string} path File path, for reports.
 * @param {string} source File text.
 * @returns {{ path: string, functions: Array<object>, globals: Set<string>, defined: Set<string>, code: string }}
 */
function analyse(path, source) {
	const code = mask(source);
	const globals = new Set();
	const defined = new Set();
	const functions = [];
	const lineOf = (offset) => source.slice(0, offset).split('\n').length;

	/** Walks a range, collecting functions; blocks are transparent. */
	function walk(from, to, context) {
		const found = definitions(code, from, to, context.inClass);
		for (const item of found) {
			if (item.kind === 'class') {
				if (context.depth === 0) {
					globals.add(item.name);
					defined.add(item.name);
				}
				walk(item.open + 1, item.close, {
					inClass: true,
					owner: null,
					depth: context.depth + 1,
					className: item.name
				});
			} else if (item.kind === 'property') {
				walk(item.open + 1, item.close, {
					inClass: false,
					owner: null,
					depth: context.depth + 1,
					property: true
				});
			} else if (item.kind === 'function') {
				if (context.depth === 0 && !context.owner && !item.anonymous) {
					globals.add(item.name);
					defined.add(item.name);
				}
				const record = {
					path,
					name: (context.className ? context.className + '.' : '') + item.name,
					params: item.params,
					open: item.open,
					close: item.close,
					outer: context.owner,
					lineOf
				};
				functions.push(record);
				walk(item.open + 1, item.close, {
					inClass: false,
					owner: record,
					depth: context.depth + 1
				});
			} else {
				walk(item.open + 1, item.close, context);
			}
		}
		return found;
	}
	walk(0, code.length, { inClass: false, owner: null, depth: 0 });
	// Script-level assignments and global declarations are global variables;
	// a function defined inside a script-level block is not script-level code.
	const fileLevel = ownText(code, 0, code.length, throughBlocks(code, 0, code.length));
	for (const name of assignedNames(fileLevel).keys()) globals.add(name);
	for (const name of referencedNames(fileLevel)) globals.add(name);
	// A one-line fat-arrow definition is a function too.
	for (const match of fileLevel.matchAll(/^[ \t]*([A-Za-z_]\w*)\([^()\n]*\)[ \t]*=>/gm)) {
		globals.add(match[1]);
		defined.add(match[1]);
	}
	for (const name of declarations(fileLevel).declared) globals.add(name);
	for (const record of functions) {
		const nested = throughBlocks(code, record.open + 1, record.close);
		record.body = ownText(code, record.open + 1, record.close, nested);
		const decl = declarations(record.body);
		record.declared = decl.declared;
		record.assumeGlobal = decl.assumeGlobal;
		for (const name of decl.globals) globals.add(name);
		record.assigned = assignedNames(record.body);
	}
	return { path, functions, globals, defined, code };
}

/**
 * Replays LocalSameAsGlobal over a set of files loaded together.
 * @param {Array<{path: string, source: string}>} files The loaded sources.
 * @returns {Array<{path: string, line: number, name: string, fn: string}>}
 */
function localSameAsGlobal(files) {
	return hitsAmong(files.map((file) => analyse(file.path, file.source)));
}

/**
 * Replays LocalSameAsGlobal over already analysed files loaded together.
 * @param {Array<object>} analysed Results of analyse(), one per file.
 * @returns {Array<{path: string, line: number, name: string, fn: string}>}
 */
function hitsAmong(analysed) {
	const globals = new Set(BUILTINS);
	for (const file of analysed) for (const name of file.globals) globals.add(name);
	const lower = new Set([...globals].map((name) => name.toLowerCase()));
	const hits = [];
	for (const file of analysed) {
		for (const fn of file.functions) {
			if (fn.assumeGlobal) continue;
			const owned = new Set([...fn.params, ...fn.declared].map((name) => name.toLowerCase()));
			for (let outer = fn.outer; outer; outer = outer.outer) {
				if (outer.assumeGlobal) break;
				for (const name of [...outer.params, ...outer.declared, ...outer.assigned.keys()])
					owned.add(name.toLowerCase());
			}
			for (const [name, at] of fn.assigned) {
				const key = name.toLowerCase();
				// A_ names are built-in variables, assigned in place, never locals.
				if (
					key === 'this' ||
					key === 'super' ||
					key.startsWith('a_') ||
					owned.has(key) ||
					!lower.has(key)
				)
					continue;
				hits.push({ path: fn.path, line: fn.lineOf(fn.open + 1 + at), name, fn: fn.name });
			}
		}
	}
	return hits;
}

module.exports = {
	BUILTINS,
	mask,
	analyse,
	hitsAmong,
	localSameAsGlobal
};
