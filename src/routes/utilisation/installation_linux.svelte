<script>
	import Ergopti from '$lib/components/Ergopti.svelte';
	import ErgoptiPlus from '$lib/components/ErgoptiPlus.svelte';
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
<div>
	{#if version_linux !== undefined}
		<tiny-space></tiny-space>
		<a href="/drivers/linux/Ergopti_v{version_linux}.xkb" download>
			<button><i class="icon-linux"></i> Ergopti_v{version_linux}.xkb</button>
		</a>
		<tiny-space></tiny-space>
		<a href="/drivers/linux/Ergopti_v{version_linux}.XCompose" download>
			<button><i class="icon-linux"></i> Ergopti_v{version_linux}.XCompose</button>
		</a>
	{/if}
	<tiny-space></tiny-space>
	<a href="/drivers/linux/install_xkb.py" download>
		<button class="alt-button"><i class="icon-linux"></i>Script d’installation XKB</button>
	</a>
</div>

<tiny-space></tiny-space>
<p>Installation d’<Ergopti></Ergopti> sur Linux (X11 et Wayland) :</p>
<ol>
	<li>Télécharger les 3 fichiers ci-dessus (XKB, XCompose et script d’installation)</li>
	<li>Exécuter le script d’installation XKB en sudo : <code>sudo python3 install_xkb.py</code></li>
	<li>Redémarrer l’ordinateur pour que les changements prennent effet.</li>
	<li>
		Modifier la disposition clavier dans les paramètres de votre environnement de bureau où la
		disposition <Ergopti></Ergopti> devrait désormais être sélectionnable dans le groupe de langues Français.
	</li>
</ol>

<h3>Résolution de problèmes connus</h3>
<p>Certains problèmes ont été rapportés avec le keylayout d’Ergopti dans quelques logiciels :</p>
<ul>
	<li>
		Le raccourci <kbd-output>Ctrl+Z</kbd-output> en <kbd>Ctrl</kbd> + <kbd>È</kbd> ne semble pas fonctionner.
		Pourtant, tous les autres raccourcis sur les lettres accentuées fonctionnent, alors qu’ils sont définis
		de la même manière.
	</li>
	<li>
		Sur Wayland, XCompose ne fonctionne pas dans certains programmes. C’est notamment le cas des
		applications Electron comme VSCode. Ce problème implique que les touches mortes ne vont pas
		fonctionner, de même pour les output de plusieurs caractères comme les ponctuations avec espaces
		insécables automatiques. Il existe peut-être des workarounds.
	</li>
	<li>
		Avec la version <ErgoptiPlus></ErgoptiPlus> directement intégrée au driver clavier, il y a les mêmes
		problèmes que sur cette même version sur macOS. Cela inclut le fait qu’un appui sur
		<kbd>Entrée</kbd>
		en état de touche morte envoie la touche morte, mais pas directement
		<kbd-output>Entrée</kbd-output>. Pour cela, il est nécessaire d’appuyer une deuxième fois sur
		cette touche. Ce problème peut probablement être résolu en utilisant un autre logiciel de
		remappage de clavier, comme cela a été corrigé sur macOS.
	</li>
</ul>
