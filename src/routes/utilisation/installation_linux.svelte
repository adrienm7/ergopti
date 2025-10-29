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

<code
	style="display:inline-block; width:100%; padding:1em; border-bottom-left-radius:0; border-bottom-right-radius:0; text-align:left"
	>curl -fsSL https://raw.githubusercontent.com/adrienm7/ergopti/dev/static/drivers/linux/install.sh
	| sh</code
>
<button
	id="copy-install-cmd"
	style="width:100%; border-top-left-radius:0; border-top-right-radius:0;"
	on:click={() => {
		const cmd =
			'curl -fsSL https://raw.githubusercontent.com/adrienm7/ergopti/dev/static/drivers/linux/install.sh | sh';
		try {
			navigator.clipboard
				.writeText(cmd)
				.then(() => {
					const el = document.getElementById('copy-install-cmd');
					if (el) {
						el.textContent = 'Code copié';
						setTimeout(
							() =>
								(el.innerHTML = '<i class="icon-linux"></i> Copier le code bash d’installation'),
							1600
						);
					}
				})
				.catch(() => {
					window.prompt('Copy command (Ctrl+C):', cmd);
				});
		} catch (e) {
			window.prompt('Copy command (Ctrl+C):', cmd);
		}
	}}
	class="download-buttons"
>
	<i class="icon-linux"></i> Copier le code bash d’installation
</button>

<p>
	Après l’installation, redémarrer l’ordinateur pour que les changements prennent effet. Modifier
	ensuite la disposition clavier dans les paramètres de votre environnement de bureau où la
	disposition <Ergopti></Ergopti> devrait désormais être sélectionnable dans le groupe de langues Français.
</p>

<tiny-space></tiny-space>

<p>
	Le processus d’installation se déroule en deux étapes. D’abord, un script de sélection choisit les
	fichiers à installer : version d’<Ergopti></Ergopti>, variante, etc. Ensuite, un script
	d’installation utilise ce qui a été sélectionné pour appliquer les modifications système
	(nécessite
	<code>sudo</code>).
</p>
<div class="download-buttons">
	<a href="/drivers/linux/xkb_files_selector.py" download>
		<button class="alt-button"
			><i class="icon-linux"></i> ➀ Script de sélection des fichiers XKB</button
		>
	</a>
	<a href="/drivers/linux/xkb_files_installer.py" download>
		<button class="alt-button"
			><i class="icon-linux"></i> ➁ Script d’installation des fichiers XKB</button
		>
	</a>
</div>

<p>Voici un résumé de ce que réalise le script d’installation :</p>
<ul>
	<li>
		<strong>Sauvegarde</strong> : création d’une copie de sauvegarde pour chaque fichier modifié.
		Par exemple,
		<code>fichier.ext.1</code> est créé comme copie de <code>fichier.ext</code> avant toute modification
		de celui-ci. Ainsi, il sera toujours possible de revenir en arrière si besoin.
	</li>

	<li>
		<strong>XKB Symbols</strong> : ajout (ou mise à jour si elle existe déjà) d’une section
		<code>xkb_symbols "..."</code>
		dans le fichier <code>/usr/share/X11/xkb/symbols/fr</code>. Ces définitions décrivent ce que
		fait chaque touche sur chacune des couches (Shift, CapsLock, AltGr, etc.).
	</li>

	<li>
		<strong>XKB Types</strong> : ajout (ou mise à jour si elles existent déjà) des définitions de
		types personnalisées d’<Ergopti></Ergopti> dans le fichier
		<code>/usr/share/X11/xkb/types/extra</code>. Les types définissent l’association entre le numéro
		de couche défini dans XKB Symbols avec les modificateurs qui doivent être pressés pour atterrir
		sur cette couche.
	</li>

	<li>
		<strong>XKB Rules & Menus</strong> : ajout (ou mise à jour si l’entrée existe déjà) des fichiers
		<code>/usr/share/X11/xkb/rules/evdev.lst</code>
		et
		<code>/usr/share/X11/xkb/rules/evdev.xml</code>. Cela permet de faire apparaître la disposition
		dans la liste des dispositions système, et donc de la sélectionner.
	</li>

	<li>
		<strong>.XCompose</strong> : création (ou remplacement s’il existe déjà) du fichier
		<code>.XCompose</code>
		dans le home de l’utilisateur (<code>~/.XCompose</code>). Cela permet d’utiliser les touches
		mortes ainsi que les sorties en plusieurs caractères, comme les ponctuations avec espaces
		insécables automatiques.
	</li>

	<li>
		<strong>Activation</strong> : enfin, le script tente d’appliquer la disposition : d’abord via
		<code>localectl set-x11-keymap</code> (si disponible), puis via <code>setxkbmap</code> dans la session
		X de l’utilisateur. Ces actions sont « best‑effort » et peuvent échouer sans annuler l’installation.
	</li>
</ul>

<p>
	En bref : le script installe la définition des touches, les types associés, met à jour les
	fichiers de règles pour que la disposition soit visible dans l’interface et installe le fichier
	.XCompose personnalisé.
</p>

<h3 id="linux-solutions">Résolution de problèmes connus</h3>
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

<h3>
	<i class="icon-kanata" style="font-size:0.8em; vertical-align:0; margin-right:0.25em"
		><span class="path1"></span><span class="path2"></span><span class="path3"></span></i
	>Kanata
</h3>

<p class="encadre">
	<b>Attention :</b> Le code Kanata suivant est encore en bêta et risque d’être régulièrement mis à jour.
	Il est totalement fonctionnel, mais des améliorations et ajouts sont encore possibles. Veillez à vérifier
	régulièrement si une nouvelle version est disponible.
</p>

<tiny-space></tiny-space>

<div class="download-buttons">
	<a href="/drivers/kanata/kanata.kbd" download>
		<button
			><i class="icon-kanata" style="font-size:0.8em; vertical-align:0; margin-right:0.25em"
				><span class="path1"></span><span class="path2"></span><span class="path3"></span></i
			>
			kanata.kbd</button
		>
	</a>
</div>

<p>
	<a href="https://github.com/jtroo/kanata" target="_blank" class="link">Kanata</a> est un outil de remappage
	de clavier open source fonctionnant sur tous les systèmes d’exploitation majeurs (Linux, macOS et Windows).
	Il permet de redéfinir le comportement des touches du clavier à l’échelle du système.
</p>
<p>Voici les fonctionnalités implémentées dans le fichier Kanata :</p>
<ul>
	<li>Tap holds sur <kbd>LShift</kbd>, <kbd>LCtrl</kbd> et <kbd>RCtrl</kbd> ;</li>
	<li>Layer de navigation en hold sur <kbd>Alt</kbd>.</li>
</ul>

<h3>
	<i class="icon-espanso" style="font-size:0.8em; vertical-align:0; margin-right:0.25em"></i>Espanso
</h3>

<p class="encadre">
	<b>Attention :</b> Le code Espanso suivant est encore en bêta et risque d’être régulièrement mis à
	jour. Il est totalement fonctionnel, mais des améliorations et ajouts sont encore possibles. Veillez
	à vérifier régulièrement si une nouvelle version est disponible.
</p>

<tiny-space></tiny-space>

<div class="download-buttons">
	<a href="https://github.com/adrienm7/ergopti/tree/main/static/drivers/espanso" target="_blank">
		<button
			><i class="icon-espanso" style="font-size:0.8em; vertical-align:0; margin-right:0.25em"></i>
			Dossier de snippets Espanso</button
		>
	</a>
</div>

<p>
	<a href="https://espanso.org/" target="_blank" class="link">Espanso</a> est un gestionnaire de snippets
	open source pour Linux, macOS et Windows. Il permet d’utiliser des snippets de texte dans n’importe
	quelle application. Cela semblerait donc être la solution parfaite, fonctionnant sur tous les systèmes
	d’exploitation et étant open source. Cependant, Espanso ne fonctionne pas aussi bien qu’Alfred sur
	macOS, notamment en termes de rapidité d’insertion des snippets. Néanmoins, c’est actuellement la meilleure
	solution disponible pour Linux.
</p>
