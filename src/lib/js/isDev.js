// Centralized dev detection utilities
export function detectDev() {
	// Client-side check for URL path
	if (typeof window === 'undefined') return false;
	return window.location.pathname.startsWith('/dev');
}

export function branchForInstall() {
	return detectDev() ? 'dev' : 'main';
}

export default { detectDev, branchForInstall };
