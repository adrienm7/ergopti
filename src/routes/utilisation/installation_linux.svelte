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

<h2 id="linux"><i class="icon-linux purple" style="margin-right:0.15em"></i>Installation Linux</h2>
<tiny-space></tiny-space>
<div>
	{#if version_linux !== undefined}
		<a href="/drivers/linux/Ergopti_v{version_linux}.xkb" download>
			<button class="bouton-telechargement"
				><i class="icon-linux"></i> Ergopti_v{version_linux}.xkb</button
			>
		</a>
		<tiny-space></tiny-space>
		<a href="/drivers/linux/Ergopti_v{version_linux}.XCompose" download>
			<button class="bouton-telechargement"
				><i class="icon-linux"></i> Ergopti_v{version_linux}.XCompose</button
			>
		</a>
	{/if}
</div>

<h3>Résolution de problèmes connus</h3>
<p>Certains problèmes ont été rapportés avec le keylayout d’Ergopti dans quelques logiciels :</p>
<ul>
	<li>
		Le raccourci <kbd-output>Ctrl+Z</kbd-output> en <kbd-output>Ctrl</kbd-output> + <kbd-output>È</kbd-output> semble ne pas fonctionner. Pourtant, tous les autres raccourcis sur les lettres accentuées fonctionnent. alors qu’ils sont définis de la même manière.
	</li>
    <li>
        Sur Wayland, XCompose ne fonctionne pas dans certains programmes. C’est notamment le cas des applications Electron comme VSCode.
        Ce problème implique que les touches mortes ne vont pas fonctionner, de même pour les output de plusieurs caractères comme les ponctuations avec espaces insécables automatiques.
        Il existe peut-être des workarounds.
    </li>
</ul>