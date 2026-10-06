// static/ergopti_plus/windows/native/nav_event_owner/editor_replace.h
/**
 * @file editor_replace.h
 * @brief Asynchronous, verified literal replacement in a focused Windows editor.
 */

#ifndef ERGOPTI_EDITOR_REPLACE_H
#define ERGOPTI_EDITOR_REPLACE_H

#include "nav_event_owner.h"
#include <stdbool.h>

/** Worker states; terminal outcomes never authorize a keyboard/paste retry. */
enum ErgoptiEditor_Phase {
	ERGOPTI_EDITOR_PREPARING = 1,
	ERGOPTI_EDITOR_READY = 2,
	ERGOPTI_EDITOR_EMITTING = 3,
	ERGOPTI_EDITOR_SUCCESS = 4,
	ERGOPTI_EDITOR_REFUSED = 5,
	ERGOPTI_EDITOR_INDETERMINATE = 6
};

/** Resource bounds keep an editor message and its copied document finite. */
#define ERGOPTI_EDITOR_MESSAGE_TIMEOUT_MS 100u
#define ERGOPTI_EDITOR_ADMISSION_TIMEOUT_MS 1000u
#define ERGOPTI_EDITOR_VISIBILITY_TIMEOUT_MS 250u
#define ERGOPTI_EDITOR_VISIBILITY_POLL_MS 5u
#define ERGOPTI_EDITOR_MAX_UNITS (1024u * 1024u)

/** Copies immutable text and starts preparation without sending input. */
ERGOPTI_NAV_API int32_t ERGOPTI_NAV_CALL ErgoptiEditor_Begin(
	uint64_t token, uint64_t window, uint64_t control, uint32_t process_id,
	const uint16_t *deleted_text, const uint16_t *inserted_text);

/** Copies phase and Win32 error; no document content crosses this receipt. */
ERGOPTI_NAV_API int32_t ERGOPTI_NAV_CALL ErgoptiEditor_Poll(
	uint64_t token, uint32_t *phase, uint32_t *os_error);

/** Authorizes the exact prepared edit, or cancels it before mutation. */
ERGOPTI_NAV_API int32_t ERGOPTI_NAV_CALL ErgoptiEditor_Decide(
	uint64_t token, uint32_t commit);

/** Releases storage only after the exact worker thread has exited. */
ERGOPTI_NAV_API int32_t ERGOPTI_NAV_CALL ErgoptiEditor_Close(uint64_t token);

/** Reports an owned worker even when the navigation hook was never started. */
int ErgoptiEditor_IsBusy(void);

/** Reserves a stop interval only when no worker owns native storage. */
bool ErgoptiEditor_TryFenceAdmission(void);
/** Releases the exact stop interval after the navigation owner returns. */
void ErgoptiEditor_UnfenceAdmission(void);

#if defined(ERGOPTI_NAV_TESTING)
/** Substitutes focus only; hidden native receiver messages remain unmodified. */
void ErgoptiEditor_TestFocus(uint64_t window, uint64_t control);
/** Observes a real visibility wait after its full image and caret are frozen. */
bool ErgoptiEditor_TestWaiting(uint64_t token);
/** Returns actual worker mutation attempts, or UINT32_MAX for an unknown token. */
uint32_t ErgoptiEditor_TestMutationCount(uint64_t token);
/** Runs the hidden native receiver regression matrix. */
bool ErgoptiEditor_TestReplacements(void);
#endif

#endif
