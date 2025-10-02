<script>
	import Ergopti from '$lib/components/Ergopti.svelte';
	import SFB from '$lib/components/SFB.svelte';
	import { version } from '$lib/stores_infos.js';
	import { getLatestVersion } from '$lib/js/getVersions.js';
	let versionValue, version_linux;
	version.subscribe((value) => {
		versionValue = value;
		version_linux = getLatestVersion('linux', value)?.replaceAll('.', '_');
	});
</script>

<h2>Installation Linux</h2>
<tiny-space></tiny-space>
<div>
	{#if version_linux !== undefined}
		<a href="/drivers/linux/Ergopti_v{version_linux}.xkb" download>
			<button class="bouton-telechargement">☛ Ergopti_v{version_linux}.xkb</button>
		</a>
		<tiny-space></tiny-space>
		<a href="/drivers/linux/Ergopti_v{version_linux}.XCompose" download>
			<button class="bouton-telechargement">☛ Ergopti_v{version_linux}.XCompose</button>
		</a>
	{/if}
</div>
