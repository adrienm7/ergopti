<!-- src/routes/ergopti-plus/configuration/+page.svelte -->

<!--
==============================================================================
MODULE: Ergopti+ — Configuration
DESCRIPTION:
Sub-page of the Ergopti+ section; it loads only its own sections. The shell
(language, version, local navigation, sticky download) is ../+layout.svelte.
==============================================================================
-->

<script>
	import { t } from '../i18n.svelte.js';
	import Customization from '../Customization.svelte';
	import Privacy from '../Privacy.svelte';

	// Populated at build time by +page.server.js from the driver's data files.
	let { data } = $props();

	// Window geometry lookup for the embedded driver frames.
	let winGeo = $derived(Object.fromEntries(data.webviews.map((w) => [w.id, w])));
</script>

<svelte:head>
	<title>{t('Configuration — Ergopti+')}</title>
	<meta
		name="description"
		content={t(
			'Les réglages d’Ergopti+, ses langues d’interface et le respect de votre vie privée.'
		)}
	/>
</svelte:head>

<h1 class="ep-subpage-title">{t('Configuration')}</h1>

<Customization locales={data.locales} webviews={data.webviews} geo={winGeo} />
<Privacy />
