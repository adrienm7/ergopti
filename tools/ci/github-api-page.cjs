// tools/ci/github-api-page.cjs

/**
 * ==============================================================================
 * MODULE: GitHub API Page Size
 * DESCRIPTION:
 * The one page size every census of a run's jobs or artifacts requests.
 *
 * ROOT CAUSE ENCODED:
 * A jobs page carries every step of every job it lists. A manual dispatch of
 * all three OS lanes runs ten macOS E2E cells of about eighty steps each, and
 * for such a run (39550661373) GitHub answered 502, or reset the stream, for
 * every jobs page of 70 or more jobs, while pages of 50 were served every
 * time. The managed Ollama handoff asked for pages of 100, so the macOS Build
 * failed while waiting for its qualified inputs, on a green run.
 * ==============================================================================
 */

'use strict';

/** Records per page for every jobs and artifacts listing of a run. */
const API_PAGE_SIZE = 50;

module.exports = { API_PAGE_SIZE };
