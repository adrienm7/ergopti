export function matomo(init, title, url) {
	// console.log('Matomo');
	var _paq = (window._paq = window._paq || []);
	if (title != null) {
		_paq.push(['setDocumentTitle', title]);
	}
	if (url != null) {
		_paq.push(['setCustomUrl', url]);
	}
	_paq.push(['trackPageView']);
	_paq.push(['enableLinkTracking']);
	(function () {
		var u = 'https://stats.beseven.fr/';
		_paq.push(['setTrackerUrl', u + 'matomo.php']);
		_paq.push(['setSiteId', '6']);
		if (init) {
			var d = document;
			var g = d.createElement('script');
			g.type = 'text/javascript';
			g.async = true;
			g.src = u + 'matomo.js';
			d.body.appendChild(g);
		}
	})();
}
