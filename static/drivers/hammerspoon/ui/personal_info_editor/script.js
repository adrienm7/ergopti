document.addEventListener('DOMContentLoaded', () => {
	// Handles closing the window gracefully if the user cancels
	const cancelBtn = document.querySelector('.cancel');
	if (cancelBtn) {
		cancelBtn.addEventListener('click', () => {
			fetch('/cancel')
				.then(() => window.close())
				.catch((err) => console.error('Error cancelling:', err));
		});
	}

	// Allows pressing Escape to cancel
	document.addEventListener('keydown', (e) => {
		if (e.key === 'Escape') {
			fetch('/cancel')
				.then(() => window.close())
				.catch((err) => console.error('Error cancelling:', err));
		}
	});
});
