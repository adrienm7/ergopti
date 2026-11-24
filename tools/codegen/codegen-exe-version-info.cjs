// tools/codegen/codegen-exe-version-info.cjs

/**
 * ==============================================================================
 * MODULE: Windows Exe Version Resource Codegen
 * DESCRIPTION:
 * Writes static/ergopti_plus/windows/_generated/exe_version_info.ahk, the
 * Ahk2Exe directives that give ErgoptiPlus.exe its product name, publisher,
 * description, copyright and links (file Properties > Details).
 *
 * WHY THIS EXISTS:
 * The directives were typed in ErgoptiPlus.ahk, so the exe's copyright, the
 * macOS Info.plist and the Linux packages each spelled their own notice. The
 * values now come from tools/lib/app-metadata.cjs through
 * tools/ci/windows-exe-version-info.cjs, which the CI check of the compiled
 * exe reads too.
 *
 * USAGE:  node tools/codegen/codegen-exe-version-info.cjs
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');
const { INCLUDE, renderInclude } = require('../ci/windows-exe-version-info.cjs');

const ROOT = path.resolve(__dirname, '..', '..');
const output = path.join(ROOT, INCLUDE);
fs.mkdirSync(path.dirname(output), { recursive: true });
fs.writeFileSync(output, renderInclude(), 'utf8');
console.log(`[OK] wrote ${INCLUDE}`);
