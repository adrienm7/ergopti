var _paq = window._paq || [];
/* tracker methods like "setCustomDimension" should be called before "trackPageView" */
_paq.push(['trackPageView']);
_paq.push(['enableLinkTracking']);
(function () {
	var u = 'https://stats.beseven.fr/';
	_paq.push(['setTrackerUrl', u + 'm.php']);
	_paq.push(['setSiteId', '6']);
	var d = document,
		g = d.createElement('script'),
		s = d.getElementsByTagName('script')[0];
	g.type = 'text/javascript';
	g.async = true;
	g.defer = true;
	g.src = u + 'm.js';
	s.parentNode.insertBefore(g, s);
})();
