// tools/codegen/codegen-prompt-builder-hs.cjs

/**
 * ==============================================================================
 * MODULE: PromptBuilder HS Codegen (no-op — direct shared module usage)
 * DESCRIPTION:
 * The Hammerspoon driver consumes the shared Lua implementation of
 * PromptBuilder directly via:
 *   require("llm.prompt_builder")        -- _shared/lua/llm/prompt_builder.lua
 * No code generation is needed because Lua modules are cross-runtime portable.
 *
 * CONTRAST WITH AHK:
 * AutoHotkey cannot require a .lua file, so codegen-prompt-builder-ahk.cjs
 * translates the algorithm to AHK v2 class syntax and writes it to
 * windows/_generated/prompt_builder.ahk.
 *
 * This script exists only to document the asymmetry and give the developer a
 * consistent "codegen:prompt-builder:hs" npm task that always succeeds.
 * ==============================================================================
 */

'use strict';

const { sharedRel } = require('../lib/paths.cjs');

const SHARED_SRC = sharedRel('lua/llm/prompt_builder.lua');
const HS_CONSUMER = 'static/ergopti_plus/macos/modules/llm/prompt_builder.lua';

console.log('codegen:prompt-builder:hs — no-op (HS uses shared Lua directly).');
console.log(`  Shared source : ${SHARED_SRC}`);
console.log(
	`  HS consumer   : ${HS_CONSUMER}  (delegates to shared via require("llm.prompt_builder"))`
);
console.log('codegen:prompt-builder:hs — done.');
