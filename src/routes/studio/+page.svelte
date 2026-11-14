<!-- src/routes/studio/+page.svelte -->

<!--
==============================================================================
MODULE: Ergopti Studio — Éditer
DESCRIPTION:
The editor tab of Ergopti Studio, an app-like workspace: it frames the shared
editor page served as-is from static/ergopti_plus/_shared/ui/layout_editor/,
the same code Ergopti+ mounts in its layout editor window, so the site and
the app can never diverge. The shell (tab bar, full-bleed frame) is
+layout.svelte. Files open with the browser's file picker and save as
downloads; nothing leaves the visitor's computer.
==============================================================================
-->

<script>
	import { asset } from '$app/paths';
	import SiteFrame from '#lib/components/SiteFrame.svelte';

	const editorSrc = asset('ergopti_plus/_shared/ui/layout_editor/index.html') + '?lang=fr';
</script>

<svelte:head>
	<title>Ergopti Studio</title>
	<meta
		name="description"
		content="Ergopti Studio : créer ou modifier sa disposition de clavier, l’enregistrer en TOML Ergopti et l’exporter"
	/>
</svelte:head>

<h1 class="studio-title">Ergopti Studio</h1>
<SiteFrame class="studio-frame" title="Ergopti Studio — Éditer" src={editorSrc} />
