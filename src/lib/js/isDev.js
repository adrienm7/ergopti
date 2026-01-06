// Centralized dev detection utilities
export function detectDev() {
	// Client-side check for URL path
	if (typeof window === 'undefined') return false;
	return window.location.pathname.startsWith('/dev');
}

export function branchForInstall() {
	// If not running in browser, default to main
	if (typeof window === 'undefined') return 'main';

	// If path explicitly indicates dev, use dev
	if (detectDev()) return 'dev';

	// If running on localhost, attempt to determine the git branch
	const host = window.location.hostname;
	if (host === 'localhost' || host === '127.0.0.1') {
		// Try to read a version/metadata file that might contain branch info.
		// Prefer the static file written at /static/version.json by the build helper.
		// We'll attempt a synchronous XHR to keep this function synchronous
		const candidates = [
			'/version.json',
			'/static/version.json',
			'/build/_app/version.json',
			'/_app/version.json'
		];
		for (let i = 0; i < candidates.length; i++) {
			const url = candidates[i];
			try {
				const req = new XMLHttpRequest();
				req.open('GET', url, false); // synchronous
				req.send(null);
				if (req.status === 200) {
					try {
						const json = JSON.parse(req.responseText);
						// Accept either a direct 'branch' field or 'version' that encodes branch
						if (json.branch && typeof json.branch === 'string') return json.branch;
						if (json.version && typeof json.version === 'string') {
							// If version looks like a timestamp, fallback to 'main'
							// Otherwise, if version contains branch-like text (e.g., 'dev'), use it
							if (json.version.includes('dev')) return 'dev';
						}
					} catch (e) {
						// ignore parse errors and continue
					}
				}
			} catch (e) {
				// ignore and try next candidate
			}
		}
		// As a last resort on localhost, assume 'dev'
		return 'dev';
	}

	// Default production branch
	return 'main';
}

export default { detectDev, branchForInstall };
