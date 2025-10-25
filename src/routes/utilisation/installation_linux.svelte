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

{#if typeof window !== 'undefined'}
	<script>
		// client-only helpers injected here to keep SSR simple
	</script>
{/if}

<div style="display:flex;align-items:center;gap:0.5rem;flex-wrap:wrap">
	<code style="display:inline-block; width:100%; text-align:left">{#if versionValue}{`curl -fsSL https://raw.githubusercontent.com/adrienm7/ergopti/dev/static/drivers/linux/install.sh | sh -s -- --version v${versionValue.replaceAll('.', '_')}`}{:else}curl -fsSL https://raw.githubusercontent.com/adrienm7/ergopti/dev/static/drivers/linux/install.sh | sh{/if}</code>
	<button id="copy-install-cmd" on:click={() => {
		const cmd = 'curl -fsSL https://raw.githubusercontent.com/adrienm7/ergopti/dev/static/drivers/linux/install.sh | sh';
		try {
			navigator.clipboard.writeText(cmd).then(() => {
				const el = document.getElementById('copy-install-cmd');
				if (el) { el.textContent = 'Code copié'; setTimeout(() => el.textContent = 'Copy', 1600); }
			}).catch(() => { window.prompt('Copy command (Ctrl+C):', cmd); });
		} catch (e) { window.prompt('Copy command (Ctrl+C):', cmd); }
	}}>
	<i class="icon-linux"></i> Copier le script d'installation
	</button>
</div>

<tiny-space></tiny-space>

<div>
	<a href="/drivers/linux/install_xkb.py" download>
		<button class="alt-button"><i class="icon-linux"></i> Script d’installation XKB</button>
	</a>
</div>

<tiny-space></tiny-space>
<p>Installation d’<Ergopti></Ergopti> sur Linux (X11 et Wayland) :</p>
<ol>
	<li>Télécharger les 3 fichiers ci-dessus (XKB, XCompose et script d’installation)</li>
	<li>
		Exécuter le script d'installation XKB en sudo. Deux façons sûres (évite les erreurs de "Permission denied") :
		<ul>
				<li>Recommandé (aucun chmod requis) : télécharger puis exécuter en une seule ligne (préserve le TTY) :
					<code>curl -fsSL -o install.sh https://raw.githubusercontent.com/adrienm7/ergopti/dev/static/drivers/linux/install.sh && sudo sh ./install.sh</code>
			</li>
			<li>Si vous avez téléchargé `install.sh` localement :
				<ul>
					<li>Exécuter sans modifier les permissions : <code>sudo sh ./install.sh</code></li>
					<li>Ou rendre le script exécutable puis l'exécuter : <code>chmod +x install.sh && sudo ./install.sh</code></li>
				</ul>
			</li>
		</ul>
	</li>
	<li>Redémarrer l’ordinateur pour que les changements prennent effet.</li>
	<li>
		Modifier la disposition clavier dans les paramètres de votre environnement de bureau où la
		disposition <Ergopti></Ergopti> devrait désormais être sélectionnable dans le groupe de langues Français.
	</li>
</ol>

<h3>Résolution de problèmes connus</h3>
<p>
	Certains problèmes ont été rapportés avec le pilote XKB d’<Ergopti></Ergopti> dans quelques logiciels :
</p>
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
