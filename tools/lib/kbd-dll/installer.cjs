// tools/lib/kbd-dll/installer.cjs

/**
 * ==============================================================================
 * MODULE: Keyboard Layout Installer (NSIS)
 * DESCRIPTION:
 * Writes the NSIS script of a standalone, unsigned installer for the four DLL
 * images build.cjs makes, and builds it with makensis on any OS. The installer
 * is only built and listed here, never run: installing needs Windows and is the
 * maintainer's check (docs/design/layout-windows-dll.md).
 *
 * FEATURES & RATIONALE:
 * 1. One DLL per Windows architecture: the native image in System32 (x86, x64
 *    or ARM64, with file-system redirection off on 64-bit Windows) and, on
 *    64-bit Windows, the WOW64 image (32-bit code, 64-bit table pointers) in
 *    SysWOW64 for 32-bit applications.
 * 2. Registration as Windows' own layouts are: HKLM\SYSTEM\CurrentControlSet\
 *    Control\Keyboard Layouts\<KLID> with Layout File, Layout Text, Layout
 *    Display Name (@%SystemRoot%\system32\<dll>.dll,-1000, the DLL's string)
 *    and a Layout Id no installed layout uses; the KLID a0nn<LCID> is the first
 *    free one, reused on an upgrade. The input profile is added and removed
 *    through input.dll's InstallLayoutOrTip, so the text services (ctfmon) list
 *    the layout like any other.
 * 3. A clean uninstall: the input profile, the KLID key, the current user's
 *    Substitutes and Preload entries naming it, the files (removed at reboot
 *    when a process still has them loaded) and the uninstall entry.
 * ==============================================================================
 */

'use strict';

const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const Model = require('./model.cjs');
const { layoutIni, STUB_INI_KEYS, STUB_MAX_TEXT } = require('./layout-ini.cjs');

const MAKENSIS = 'makensis';
// The makensis release the generic installer is built with: its bytes depend on
// the release (3.09 and 3.10 give different files), and the committed stub
// (layout_editor/_generated/kbd_setup_stub.js) must equal a fresh build. This
// is the release CI installs (ubuntu-26.04 runners, nsis 3.10-2ubuntu2); a
// runner whose makensis differs is refused by name instead of reading « stale ».
const STUB_MAKENSIS_VERSION = 'v3.10-2';
const UNINSTALL_ROOT = 'Software\\Microsoft\\Windows\\CurrentVersion\\Uninstall';
const LAYOUTS_KEY = 'SYSTEM\\CurrentControlSet\\Control\\Keyboard Layouts';
// InstallLayoutOrTip flags (input.dll): 0 adds the profile, ILOT_UNINSTALL removes it.
const ILOT_UNINSTALL = 1;

/** A string inside an NSIS double-quoted literal. */
function nsisString(text, field) {
	if (typeof text !== 'string' || /[\u0000-\u001f]/.test(text))
		throw new Error(`kbd_installer_text: ${field}`);
	return text.replace(/\$/g, '$$$$').replace(/"/g, '$\\"');
}

/**
 * The values a script names, as NSIS text: literals in a layout's own
 * installer, runtime variables in the generic one ($DLL, $TEXT…).
 * @typedef {{dll: string, text: string, company: string, lcid: string, lang: string, uninstallKey: string}} Names
 */

/** The functions that pick a free KLID a0nn<LCID> and a free Layout Id. */
function allocationLines(names) {
	return [
		'; The first free KLID a0nn<LCID>: no installed layout may use it.',
		'Function AllocateKlid',
		'\tStrCpy $0 1',
		'\t${Do}',
		'\t\tIntFmt $1 "%02x" $0',
		`\t\tStrCpy $KLID "a0$1${names.lcid}"`,
		'\t\tClearErrors',
		`\t\tReadRegStr $2 HKLM "${LAYOUTS_KEY}\\$KLID" "Layout File"`,
		'\t\t${If} ${Errors}',
		'\t\t\tReturn',
		'\t\t${EndIf}',
		'\t\tIntOp $0 $0 + 1',
		'\t${LoopUntil} $0 > 255',
		'\tMessageBox MB_ICONSTOP "No free keyboard layout identifier is left."',
		'\tAbort',
		'FunctionEnd',
		'',
		'; A Layout Id one above every installed one, so no two layouts share it.',
		'Function AllocateLayoutId',
		'\tStrCpy $3 0',
		'\tStrCpy $0 0',
		'\t${Do}',
		`\t\tEnumRegKey $1 HKLM "${LAYOUTS_KEY}" $0`,
		'\t\t${If} $1 == ""',
		'\t\t\t${Break}',
		'\t\t${EndIf}',
		`\t\tReadRegStr $2 HKLM "${LAYOUTS_KEY}\\$1" "Layout Id"`,
		'\t\t${If} $2 != ""',
		'\t\t\tIntOp $2 0x$2 + 0',
		'\t\t\t${If} $2 > $3',
		'\t\t\t\tStrCpy $3 $2',
		'\t\t\t${EndIf}',
		'\t\t${EndIf}',
		'\t\tIntOp $0 $0 + 1',
		'\t${Loop}',
		'\tIntOp $3 $3 + 1',
		'\tIntFmt $LAYOUTID "%04X" $3',
		'FunctionEnd',
		''
	];
}

/** The KLID of an upgrade, else a new one, and the Layout Id that goes with it. */
function identifierLines(names) {
	return [
		`\tReadRegStr $KLID HKLM "${names.uninstallKey}" "KLID"`,
		'\t${If} $KLID == ""',
		'\t\tCall AllocateKlid',
		'\t\tCall AllocateLayoutId',
		'\t${Else}',
		`\t\tReadRegStr $LAYOUTID HKLM "${LAYOUTS_KEY}\\$KLID" "Layout Id"`,
		'\t\t${If} $LAYOUTID == ""',
		'\t\t\tCall AllocateLayoutId',
		'\t\t${EndIf}',
		'\t${EndIf}'
	];
}

/** The four DLL copies by Windows architecture; place(arch) gives one copy's lines. */
function fileLines(place) {
	return [
		'\t${If} ${IsNativeARM64}',
		'\t\t${DisableX64FSRedirection}',
		'\t\tSetOutPath "$WINDIR\\System32"',
		...place('arm64'),
		'\t\t${EnableX64FSRedirection}',
		'\t\tSetOutPath "$WINDIR\\SysWOW64"',
		...place('wow64'),
		'\t${ElseIf} ${RunningX64}',
		'\t\t${DisableX64FSRedirection}',
		'\t\tSetOutPath "$WINDIR\\System32"',
		...place('x64'),
		'\t\t${EnableX64FSRedirection}',
		'\t\tSetOutPath "$WINDIR\\SysWOW64"',
		...place('wow64'),
		'\t${Else}',
		'\t\tSetOutPath "$WINDIR\\System32"',
		...place('x86'),
		'\t${EndIf}'
	];
}

/**
 * The registry entries Windows reads for a layout, the input profile and the
 * uninstall entry: the same lines in a layout's installer and the generic one.
 */
function registrationLines(names) {
	return [
		`\tWriteRegStr HKLM "${LAYOUTS_KEY}\\$KLID" "Layout File" "${names.dll}.dll"`,
		`\tWriteRegStr HKLM "${LAYOUTS_KEY}\\$KLID" "Layout Text" "${names.text}"`,
		`\tWriteRegExpandStr HKLM "${LAYOUTS_KEY}\\$KLID" "Layout Display Name" "@%SystemRoot%\\system32\\${names.dll}.dll,-1000"`,
		`\tWriteRegStr HKLM "${LAYOUTS_KEY}\\$KLID" "Layout Id" "$LAYOUTID"`,
		`\tSystem::Call 'input::InstallLayoutOrTip(w "${names.lang}:$KLID", i 0) i .r0'`,
		'\t${If} $0 == 0',
		'\t\tDetailPrint "The input profile could not be added; add the layout in Settings."',
		'\t${EndIf}',
		'\tWriteUninstaller "$INSTDIR\\uninstall.exe"',
		`\tWriteRegStr HKLM "${names.uninstallKey}" "DisplayName" "${names.text}"`,
		`\tWriteRegStr HKLM "${names.uninstallKey}" "Publisher" "${names.company}"`,
		`\tWriteRegStr HKLM "${names.uninstallKey}" "UninstallString" '"$INSTDIR\\uninstall.exe"'`,
		`\tWriteRegStr HKLM "${names.uninstallKey}" "KLID" "$KLID"`,
		`\tWriteRegDWORD HKLM "${names.uninstallKey}" "NoModify" 1`,
		`\tWriteRegDWORD HKLM "${names.uninstallKey}" "NoRepair" 1`
	];
}

/** Removes the values of a current-user list whose data is $R0. */
const DROP_VALUES_MACRO = [
	'; Removes the values of a current-user list whose data is $R0.',
	'!macro DropValues KEY',
	'\tStrCpy $0 0',
	'\t${Do}',
	'\t\tEnumRegValue $1 HKCU "${KEY}" $0',
	'\t\t${If} $1 == ""',
	'\t\t\t${Break}',
	'\t\t${EndIf}',
	'\t\tReadRegStr $2 HKCU "${KEY}" $1',
	'\t\t${If} $2 == $R0',
	'\t\t\tDeleteRegValue HKCU "${KEY}" $1',
	'\t\t${Else}',
	'\t\t\tIntOp $0 $0 + 1',
	'\t\t${EndIf}',
	'\t${Loop}',
	'!macroend',
	''
];

/** Everything an install wrote, removed again: the same in both installers. */
function unregistrationLines(names, checks = []) {
	return [
		`\tReadRegStr $KLID HKLM "${names.uninstallKey}" "KLID"`,
		...checks,
		'\t${If} $KLID != ""',
		`\t\tSystem::Call 'input::InstallLayoutOrTip(w "${names.lang}:$KLID", i ${ILOT_UNINSTALL}) i .r0'`,
		'\t\t; A substitute naming the KLID, then the Preload entries naming that substitute or the KLID.',
		'\t\tStrCpy $0 0',
		'\t\t${Do}',
		'\t\t\tEnumRegValue $1 HKCU "Keyboard Layout\\Substitutes" $0',
		'\t\t\t${If} $1 == ""',
		'\t\t\t\t${Break}',
		'\t\t\t${EndIf}',
		'\t\t\tReadRegStr $2 HKCU "Keyboard Layout\\Substitutes" $1',
		'\t\t\t${If} $2 == $KLID',
		'\t\t\t\tStrCpy $R0 $1',
		'\t\t\t\t!insertmacro DropValues "Keyboard Layout\\Preload"',
		'\t\t\t\tDeleteRegValue HKCU "Keyboard Layout\\Substitutes" $1',
		'\t\t\t${Else}',
		'\t\t\t\tIntOp $0 $0 + 1',
		'\t\t\t${EndIf}',
		'\t\t${Loop}',
		'\t\tStrCpy $R0 $KLID',
		'\t\t!insertmacro DropValues "Keyboard Layout\\Preload"',
		`\t\tDeleteRegKey HKLM "${LAYOUTS_KEY}\\$KLID"`,
		'\t${EndIf}',
		'\t${If} ${RunningX64}',
		'\t\t${DisableX64FSRedirection}',
		`\t\tDelete /REBOOTOK "$WINDIR\\System32\\${names.dll}.dll"`,
		'\t\t${EnableX64FSRedirection}',
		`\t\tDelete /REBOOTOK "$WINDIR\\SysWOW64\\${names.dll}.dll"`,
		'\t${Else}',
		`\t\tDelete /REBOOTOK "$WINDIR\\System32\\${names.dll}.dll"`,
		'\t${EndIf}',
		`\tDeleteRegKey HKLM "${names.uninstallKey}"`,
		'\tDelete "$INSTDIR\\uninstall.exe"'
	];
}

/**
 * The NSIS script of a layout's installer. The DLLs are read from
 * `<arch>/<dll_name>.dll` beside the script.
 * @param {object} model - A checked kbd tables model.
 * @param {{output: string}} options - The installer's file name.
 * @returns {string}
 */
function emitNsis(model, options) {
	Model.check(model);
	const dll = model.dll_name;
	const text = nsisString(model.layout_text, 'layout_text');
	const names = {
		dll,
		text,
		company: nsisString(model.company || 'Ergopti', 'company'),
		lcid: model.lcid,
		lang: model.lcid.toUpperCase(),
		uninstallKey: `${UNINSTALL_ROOT}\\Ergopti_kbd_${dll}`
	};
	const lines = [
		'; Generated by tools/lib/kbd-dll/installer.cjs; edit the layout source instead.',
		'Unicode true',
		'ManifestDPIAware true',
		'!include "LogicLib.nsh"',
		'!include "x64.nsh"',
		'!include "WinVer.nsh"',
		`Name "${text}"`,
		`OutFile "${nsisString(options.output, 'output')}"`,
		'RequestExecutionLevel admin',
		`InstallDir "$PROGRAMFILES\\Ergopti\\Keyboard layouts\\${dll}"`,
		'ShowInstDetails show',
		'ShowUninstDetails show',
		'Var KLID',
		'Var LAYOUTID',
		'Page instfiles',
		'UninstPage uninstConfirm',
		'UninstPage instfiles',
		'',
		'Function .onInit',
		'\t${IfNot} ${AtLeastWin10}',
		'\t\tMessageBox MB_ICONSTOP "Windows 10 or later is required."',
		'\t\tAbort',
		'\t${EndIf}',
		'\t${If} ${RunningX64}',
		'\t\tSetRegView 64',
		'\t${EndIf}',
		'FunctionEnd',
		'',
		'Function un.onInit',
		'\t${If} ${RunningX64}',
		'\t\tSetRegView 64',
		'\t${EndIf}',
		'FunctionEnd',
		'',
		...allocationLines(names),
		'Section "Install"',
		'\tSetOutPath "$INSTDIR"',
		...identifierLines(names),
		...fileLines((arch) => [`\t\tFile "/oname=${dll}.dll" "${arch}\\${dll}.dll"`]),
		'\tSetOutPath "$INSTDIR"',
		...registrationLines(names),
		'SectionEnd',
		'',
		...DROP_VALUES_MACRO,
		'Section "Uninstall"',
		...unregistrationLines(names),
		'\tRMDir "$INSTDIR"',
		'SectionEnd',
		''
	];
	return lines.join('\n');
}

const STUB_FILE = 'ergopti-layout-setup.exe';

/** The checks and helpers of the generic installer, for its install (UN '') and uninstall (UN 'un.') sides. */
function stubFunctions(un) {
	const refuse = (why) => [`\t\tMessageBox MB_ICONSTOP "${why}"`, '\t\tAbort'];
	return [
		`; ${un ? 'Uninstall' : 'Install'} side: $OK is 1 when every character of $TEXTIN is in $ALLOWED.`,
		`Function ${un}OnlyChars`,
		'\tStrCpy $OK 1',
		'\tStrLen $R3 $TEXTIN',
		'\tStrCpy $R4 0',
		'\t${While} $R4 < $R3',
		'\t\tStrCpy $R5 $TEXTIN 1 $R4',
		'\t\tStrLen $R6 $ALLOWED',
		'\t\tStrCpy $R7 0',
		'\t\tStrCpy $R8 0',
		'\t\t${While} $R7 < $R6',
		'\t\t\tStrCpy $R9 $ALLOWED 1 $R7',
		'\t\t\t${If} $R9 S== $R5',
		'\t\t\t\tStrCpy $R8 1',
		'\t\t\t\t${Break}',
		'\t\t\t${EndIf}',
		'\t\t\tIntOp $R7 $R7 + 1',
		'\t\t${EndWhile}',
		'\t\t${If} $R8 == 0',
		'\t\t\tStrCpy $OK 0',
		'\t\t\t${Break}',
		'\t\t${EndIf}',
		'\t\tIntOp $R4 $R4 + 1',
		'\t${EndWhile}',
		'FunctionEnd',
		'',
		'; Reads $FOLDER\\layout.ini and refuses any file but the exact one layoutIni writes.',
		`Function ${un}ReadLayoutIni`,
		'\tStrCpy $INI "$FOLDER\\layout.ini"',
		'\t${IfNot} ${FileExists} "$INI"',
		...refuse('layout.ini is missing beside the installer.'),
		'\t${EndIf}',
		...STUB_INI_KEYS.map(
			(key) =>
				`\tReadINIStr ${{ dll_name: '$DLL', lcid: '$LCID', layout_text: '$TEXT', company: '$COMPANY' }[key]} "$INI" "layout" "${key}"`
		),
		'\tStrCpy $EXPECTED "[layout]$\\r$\\ndll_name=$DLL$\\r$\\nlcid=$LCID$\\r$\\nlayout_text=$TEXT$\\r$\\ncompany=$COMPANY$\\r$\\n"',
		'\tStrCpy $READ ""',
		'\tFileOpen $R1 "$INI" r',
		'\t${Do}',
		'\t\tClearErrors',
		'\t\tFileReadUTF16LE $R1 $R2',
		'\t\t${If} ${Errors}',
		'\t\t\t${Break}',
		'\t\t${EndIf}',
		'\t\tStrCpy $READ "$READ$R2"',
		'\t\tStrLen $R3 $READ',
		'\t\t${If} $R3 > 512',
		'\t\t\t${Break}',
		'\t\t${EndIf}',
		'\t${Loop}',
		'\tFileClose $R1',
		'\t${IfNot} $READ S== $EXPECTED',
		...refuse('layout.ini is not the file the layout editor wrote.'),
		'\t${EndIf}',
		'\tStrLen $R3 $DLL',
		'\tStrCpy $R5 $DLL 1',
		'\tStrCpy $TEXTIN $R5',
		'\tStrCpy $ALLOWED "abcdefghijklmnopqrstuvwxyz"',
		`\tCall ${un}OnlyChars`,
		'\t${If} $R3 < 1',
		'\t${OrIf} $R3 > 8',
		'\t${OrIf} $OK != 1',
		...refuse('layout.ini names no valid layout file.'),
		'\t${EndIf}',
		'\tStrCpy $TEXTIN $DLL',
		'\tStrCpy $ALLOWED "abcdefghijklmnopqrstuvwxyz0123456789"',
		`\tCall ${un}OnlyChars`,
		'\t${If} $OK != 1',
		...refuse('layout.ini names no valid layout file.'),
		'\t${EndIf}',
		'\tStrLen $R3 $LCID',
		'\tStrCpy $TEXTIN $LCID',
		'\tStrCpy $ALLOWED "0123456789abcdef"',
		`\tCall ${un}OnlyChars`,
		'\t${If} $R3 != 4',
		'\t${OrIf} $OK != 1',
		...refuse('layout.ini names no valid language.'),
		'\t${EndIf}',
		...['$TEXT', '$COMPANY'].flatMap((field) => [
			`\tStrLen $R3 ${field}`,
			'\t${If} $R3 < 1',
			`\t\${OrIf} $R3 > ${STUB_MAX_TEXT}`,
			...refuse('layout.ini holds a name that is empty or too long.'),
			'\t${EndIf}'
		]),
		`\t\${${un ? 'UnStrCase' : 'StrCase'}} $LANG $LCID "U"`,
		`\tStrCpy $UNKEY "${UNINSTALL_ROOT}\\Ergopti_kbd_$DLL"`,
		'FunctionEnd',
		'',
		"; Refuses a KLID out of this installer's range a001<LCID> to a0ff<LCID>.",
		`Function ${un}CheckKlid`,
		'\t${If} $KLID == ""',
		'\t\tReturn',
		'\t${EndIf}',
		'\tStrLen $R3 $KLID',
		'\tStrCpy $R4 $KLID 2',
		'\tStrCpy $R5 $KLID 2 2',
		'\tStrCpy $R6 $KLID 4 4',
		'\tStrCpy $TEXTIN $R5',
		'\tStrCpy $ALLOWED "0123456789abcdef"',
		`\tCall ${un}OnlyChars`,
		'\t${If} $R3 != 8',
		'\t${OrIfNot} $R4 S== "a0"',
		'\t${OrIfNot} $R6 S== $LCID',
		'\t${OrIf} $OK != 1',
		'\t${OrIf} $R5 S== "00"',
		...refuse('The recorded keyboard layout identifier is out of range.'),
		'\t${EndIf}',
		'FunctionEnd',
		''
	];
}

/**
 * The NSIS script of the generic installer: one unsigned stub for every
 * layout the editor builds (site and app), so no page needs makensis. It reads
 * layout.ini and the four DLLs beside it (<arch>/<dll_name>.dll), refuses any
 * other layout.ini than layoutIni writes, a missing DLL or a KLID out of its
 * range, and writes the same registry entries as a layout's own installer.
 * @returns {string}
 */
function emitStubNsis() {
	const names = {
		dll: '$DLL',
		text: '$TEXT',
		company: '$COMPANY',
		lcid: '$LCID',
		lang: '$LANG',
		uninstallKey: '$UNKEY'
	};
	return [
		'; Generated by tools/lib/kbd-dll/installer.cjs (emitStubNsis); edit the generator instead.',
		'Unicode true',
		'ManifestDPIAware true',
		'!include "LogicLib.nsh"',
		'!include "x64.nsh"',
		'!include "WinVer.nsh"',
		'!include "FileFunc.nsh"',
		'!include "StrFunc.nsh"',
		'${StrCase}',
		'${UnStrCase}',
		'Name "Ergopti keyboard layout"',
		`OutFile "${STUB_FILE}"`,
		'RequestExecutionLevel admin',
		'ShowInstDetails show',
		'ShowUninstDetails show',
		...[
			'KLID',
			'LAYOUTID',
			'DLL',
			'TEXT',
			'COMPANY',
			'LCID',
			'LANG',
			'UNKEY',
			'INI',
			'FOLDER',
			'EXPECTED',
			'READ',
			'TEXTIN',
			'ALLOWED',
			'OK'
		].map((name) => `Var ${name}`),
		'Page instfiles',
		'UninstPage uninstConfirm',
		'UninstPage instfiles',
		'',
		...stubFunctions(''),
		...stubFunctions('un.'),
		'Function .onInit',
		'\t${IfNot} ${AtLeastWin10}',
		'\t\tMessageBox MB_ICONSTOP "Windows 10 or later is required."',
		'\t\tAbort',
		'\t${EndIf}',
		'\t${If} ${RunningX64}',
		'\t\tSetRegView 64',
		'\t${EndIf}',
		'\tStrCpy $FOLDER $EXEDIR',
		'\tCall ReadLayoutIni',
		...['x86', 'wow64', 'x64', 'arm64'].flatMap((arch) => [
			`\t\${IfNot} \${FileExists} "$EXEDIR\\${arch}\\$DLL.dll"`,
			`\t\tMessageBox MB_ICONSTOP "${arch}\\$DLL.dll is missing beside the installer."`,
			'\t\tAbort',
			'\t${EndIf}'
		]),
		'\tStrCpy $INSTDIR "$PROGRAMFILES\\Ergopti\\Keyboard layouts\\$DLL"',
		'FunctionEnd',
		'',
		'Function un.onInit',
		'\t${If} ${RunningX64}',
		'\t\tSetRegView 64',
		'\t${EndIf}',
		'\tStrCpy $FOLDER $INSTDIR',
		'\tCall un.ReadLayoutIni',
		'FunctionEnd',
		'',
		...allocationLines(names),
		'Section "Install"',
		'\tSetOutPath "$INSTDIR"',
		...identifierLines(names),
		'\tCall CheckKlid',
		...fileLines((arch) => [
			`\t\tCopyFiles /SILENT "$EXEDIR\\${arch}\\$DLL.dll" "$OUTDIR\\$DLL.dll"`
		]),
		'\tSetOutPath "$INSTDIR"',
		'\tCopyFiles /SILENT "$EXEDIR\\layout.ini" "$INSTDIR\\layout.ini"',
		...registrationLines(names),
		'SectionEnd',
		'',
		...DROP_VALUES_MACRO,
		'Section "Uninstall"',
		...unregistrationLines(names, ['\tCall un.CheckKlid']),
		'\tDelete "$INSTDIR\\layout.ini"',
		'\tRMDir "$INSTDIR"',
		'SectionEnd',
		''
	].join('\n');
}

/**
 * Builds the generic installer with makensis.
 * @returns {{script: string, file: string, bytes: Buffer}}
 */
function buildStub() {
	const version = makensisVersion();
	if (version !== STUB_MAKENSIS_VERSION)
		throw new Error(
			`kbd_installer_version: makensis ${version} builds other bytes than the pinned ` +
				`${STUB_MAKENSIS_VERSION}; build the stub with that release, or move the pin ` +
				'(installer.cjs STUB_MAKENSIS_VERSION) and regenerate with npm run codegen:kbd-setup-stub:js'
		);
	const script = emitStubNsis();
	const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'kbd-stub-'));
	try {
		fs.writeFileSync(path.join(dir, 'stub.nsi'), script);
		const run = spawnSync(MAKENSIS, ['-V2', '-INPUTCHARSET', 'UTF8', 'stub.nsi'], {
			cwd: dir,
			encoding: 'utf8'
		});
		if (run.error) throw new Error(`kbd_installer_tool: ${run.error.message}`);
		if (run.status !== 0)
			throw new Error(`kbd_installer_build: ${(run.stdout + run.stderr).trim().slice(-2000)}`);
		return { script, file: STUB_FILE, bytes: fs.readFileSync(path.join(dir, STUB_FILE)) };
	} finally {
		fs.rmSync(dir, { recursive: true, force: true });
	}
}

/** Whether makensis can be run. */
function makensisAvailable() {
	return spawnSync(MAKENSIS, ['-VERSION'], { encoding: 'utf8' }).status === 0;
}

/**
 * The release of the makensis on PATH, as it prints it (e.g. v3.10-2).
 * @returns {string}
 * @throws {Error} When makensis cannot be run.
 */
function makensisVersion() {
	const run = spawnSync(MAKENSIS, ['-VERSION'], { encoding: 'utf8' });
	if (run.error || run.status !== 0)
		throw new Error(
			`kbd_installer_tool: ${run.error ? run.error.message : 'makensis -VERSION failed'}`
		);
	return run.stdout.trim();
}

/**
 * Builds the installer of a model from its four DLL images.
 * @param {object} model
 * @param {Object<string, Uint8Array>} dlls - arch -> image (x86, wow64, x64, arm64).
 * @returns {{script: string, file: string, bytes: Buffer}}
 */
function buildInstaller(model, dlls) {
	for (const arch of ['x86', 'wow64', 'x64', 'arm64'])
		if (!dlls[arch]) throw new Error(`kbd_installer_image: ${arch}`);
	const file = `${model.dll_name}-setup.exe`;
	const script = emitNsis(model, { output: file });
	const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'kbd-installer-'));
	try {
		for (const [arch, bytes] of Object.entries(dlls)) {
			fs.mkdirSync(path.join(dir, arch));
			fs.writeFileSync(path.join(dir, arch, `${model.dll_name}.dll`), bytes);
		}
		fs.writeFileSync(path.join(dir, 'installer.nsi'), script);
		const run = spawnSync(MAKENSIS, ['-V2', '-INPUTCHARSET', 'UTF8', 'installer.nsi'], {
			cwd: dir,
			encoding: 'utf8'
		});
		if (run.error) throw new Error(`kbd_installer_tool: ${run.error.message}`);
		if (run.status !== 0)
			throw new Error(`kbd_installer_build: ${(run.stdout + run.stderr).trim().slice(-2000)}`);
		return { script, file, bytes: fs.readFileSync(path.join(dir, file)) };
	} finally {
		fs.rmSync(dir, { recursive: true, force: true });
	}
}

module.exports = {
	emitNsis,
	buildInstaller,
	emitStubNsis,
	buildStub,
	layoutIni,
	registrationLines,
	unregistrationLines,
	makensisAvailable,
	makensisVersion,
	STUB_MAKENSIS_VERSION,
	LAYOUTS_KEY,
	STUB_FILE,
	STUB_INI_KEYS
};
