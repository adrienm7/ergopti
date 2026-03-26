// ui/personal_info_editor/script.js

// ===========================================================================
// Personal Info Editor UI Script.
//
// Handles the interactions for the personal information editor window.
// Includes cancellation logic via buttons and keyboard shortcuts.
// ===========================================================================

// =================================
// =================================
// ======= 1/ Core Functions =======
// =================================
// =================================

/**
 * Sends a cancellation request to the local server and securely closes the window.
 */
function executeCancellation() {
	fetch('/cancel')
		.then(() => window.close())
		.catch((error) => console.error("Erreur lors de l'annulation :", error));
}

// ===============================
// ===============================
// ======= 2/ Event Wiring =======
// ===============================
// ===============================

document.addEventListener('DOMContentLoaded', () => {
	const cancelButton = document.querySelector('.cancel');

	// Bind the cancel button click event
	if (cancelButton) {
		cancelButton.addEventListener('click', executeCancellation);
	}

	// Bind the Escape key global shortcut
	document.addEventListener('keydown', (event) => {
		if (event.key === 'Escape') {
			executeCancellation();
		}
	});
});
