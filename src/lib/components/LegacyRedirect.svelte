<!-- src/lib/components/LegacyRedirect.svelte -->

<!--
==============================================================================
MODULE: Legacy Page Redirect
DESCRIPTION:
Prerendered page that forwards a former address of the site to its new home.
GitHub Pages serves the site without a server, so the redirect runs in the
page: an inline script replaces the location before anything renders and
carries the anchor along, sending an anchor that moved to another sub-page
to that sub-page; a meta refresh covers visitors without JavaScript, and a
client-side navigation follows the same map once the page mounts. A target
may carry a query (/studio/essayer?layout=ergopti), the visited address's own
query added after it.
==============================================================================
-->

<script>
	import { onMount } from 'svelte';
	import { goto } from '$app/navigation';
	import { resolve } from '$app/paths';
	import { LEGACY_PAGES, legacyTarget, resolveWithQuery } from '#lib/js/siteNavigation.js';

	/** @type {{ from: keyof typeof LEGACY_PAGES }} */
	let { from } = $props();

	let legacy = $derived.by(() => {
		const entry = LEGACY_PAGES[from];
		if (!entry) throw new Error('LegacyRedirect: unknown former page ' + from);
		return entry;
	});

	// The base path ('' or '/dev') is read from the address itself, so the
	// script does not depend on how the page was reached (with or without a
	// trailing slash, which a relative URL would not survive).
	let forward = $derived(
		'<scr' +
			'ipt>(function(){var p=' +
			JSON.stringify(from) +
			',t=' +
			JSON.stringify(legacy.target) +
			',a=' +
			JSON.stringify(legacy.anchors) +
			',l=location,b=l.pathname.replace(/\\/+$/,"");b=b.slice(0,b.length-p.length);' +
			'var h=l.hash.slice(1),k=h;try{k=decodeURIComponent(h)}catch(e){}' +
			'var d=h&&a[k]?a[k]:t,q=l.search;if(q&&d.indexOf("?")>=0)q="&"+q.slice(1);' +
			'window.__ergoptiLegacyRedirect=true;l.replace(b+d+q+l.hash)})();</scr' +
			'ipt>'
	);

	onMount(() => {
		if (window.__ergoptiLegacyRedirect) return;
		const [route, anchor] = legacyTarget(legacy, location.hash).split('#');
		goto(resolveWithQuery(route, resolve) + (anchor ? '#' + anchor : ''), { replaceState: true });
	});
</script>

<svelte:head>
	<title>Page déplacée</title>
	<meta name="robots" content="noindex" />
	{@html forward}
	<meta http-equiv="refresh" content={'0;url=' + resolveWithQuery(legacy.target, resolve)} />
</svelte:head>

<bloc-introduction>
	<p class="legacy-redirect">
		Cette page a déménagé : <a href={resolveWithQuery(legacy.target, resolve)}>suivre le lien</a>.
	</p>
</bloc-introduction>

<style>
	.legacy-redirect {
		text-align: center;
	}
</style>
