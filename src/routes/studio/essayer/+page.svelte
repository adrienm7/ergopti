<!-- src/routes/studio/essayer/+page.svelte -->

<!--
==============================================================================
MODULE: Ergopti Studio — Essayer
DESCRIPTION:
The « Essayer » tab of Ergopti Studio (maintainer, 2026-11-21): type with any
layout of the Studio's library in the browser. It frames the shared page
served as-is from static/ergopti_plus/_shared/ui/layout_try/, which takes the
layout of this address's ?layout= (Ergopti when it names none), and keeps the
layout the visitor picks in this address so it can be shared. The former
« Essayer » page (/ergopti/utilisation) redirects here with layout=ergopti,
its anchors (#input-text, #keyboard_emulation) handed on to the frame.
==============================================================================
-->

<script>
	import { onMount } from 'svelte';
	import { asset } from '$app/paths';
	import { browser } from '$app/environment';
	import { replaceState } from '$app/navigation';
	import SiteFrame from '#lib/components/SiteFrame.svelte';
	import { trySrc, TRY_LAYOUT_MESSAGE } from '#lib/js/tryLink.js';

	// SiteFrame sets the address on the client only, so the visited query is known there.
	const frameSrc = trySrc(
		asset('ergopti_plus/_shared/ui/layout_try/index.html'),
		browser ? location.search : '',
		browser ? location.hash : ''
	);

	onMount(() => {
		// The layout picked in the frame goes into this address (?layout=), to be shared.
		const follow = (event) => {
			if (event.origin !== location.origin || !event.data) return;
			if (event.data.type !== TRY_LAYOUT_MESSAGE || typeof event.data.layout !== 'string') return;
			const url = new URL(location.href);
			url.searchParams.set('layout', event.data.layout);
			replaceState(url, {});
		};
		window.addEventListener('message', follow);
		return () => window.removeEventListener('message', follow);
	});
</script>

<svelte:head>
	<title>Essayer une disposition — Ergopti Studio</title>
	<meta
		name="description"
		content="Ergopti Studio : taper dans le navigateur avec la disposition Ergopti ou une autre disposition de la bibliothèque, touches mortes et AltGr compris"
	/>
</svelte:head>

<h1 class="studio-title">Essayer une disposition</h1>
<SiteFrame class="studio-frame" title="Ergopti Studio — Essayer" src={frameSrc} />
