<script>
	import { onMount } from 'svelte';
	import Ergopti from '$lib/components/Ergopti.svelte';
	import ErgoptiPlus from '$lib/components/ErgoptiPlus.svelte';
	import { getRelease, getRawUrl } from '$lib/js/getGitHubRelease.js';
	import { branchForInstall } from '$lib/js/isDev.js';

	/** @type {Awaited<ReturnType<typeof getRelease>>} */
	let release = null;

	const branch = branchForInstall();

	// Commande bash d'installation : pointe vers le bon branch selon le contexte
	const cmd = `branch="${branch}"; curl -fsSL "https://raw.githubusercontent.com/adrienm7/ergopti/$branch/static/ergopti/linux/xkb_installation/install.sh" | BRANCH="$branch" bash`;

	// URLs des scripts d'installation (servis depuis le raw du dépôt au bon branch)
	const urlInstallSh = getRawUrl('static/ergopti/linux/xkb_installation/install.sh');
	const urlDetectSh = getRawUrl(
		'static/ergopti/linux/xkb_installation/detect_installation_method.sh'
	);
	const urlInstallerClean = getRawUrl(
		'static/ergopti/linux/xkb_installation/xkb_files_installer_clean.py'
	);
	const urlInstallerLegacy = getRawUrl(
		'static/ergopti/linux/xkb_installation/xkb_files_installer_legacy.py'
	);

	onMount(async () => {
		release = await getRelease();
	});
</script>

<h2 id="linux"><i class="icon-linux purple" style="margin-right:0.15em"></i>Installation Linux</h2>

<code
	style="display:inline-block; width:100%; padding:1em; border-bottom-left-radius:0; border-bottom-right-radius:0; text-align:left"
	>{cmd}</code
>
<button
	id="copy-install-cmd"
	style="width:100%; border-top-left-radius:0; border-top-right-radius:0;"
	on:click={() => {
		try {
			navigator.clipboard
				.writeText(cmd)
				.then(() => {
					const el = document.getElementById('copy-install-cmd');
					if (el) {
						el.textContent = 'Code copié';
						setTimeout(
							() =>
								(el.innerHTML = `<i class="icon-linux"></i> Copier le code bash d’installation`),
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
	<i class="icon-linux"></i> Copier le code bash d'installation
</button>

<p>
	Après l'installation, <strong>redémarrer l'ordinateur</strong> pour que les changements prennent effet.
</p>
<p>
	Modifier ensuite la disposition clavier dans les paramètres de votre environnement de bureau. La
	disposition <Ergopti></Ergopti> devrait désormais être sélectionnable dans le groupe de langues Français,
	ou en tant que groupe de langue à part entière selon la méthode d'installation choisie.
	<strong>À noter :</strong> Les scripts d'installation tentent d'appliquer la disposition automatiquement,
	ce qui rend cette étape de sélection de la disposition après redémarrage parfois inutile.
</p>

<tiny-space></tiny-space>
<hr />
<tiny-space></tiny-space>

<p>
	Le processus d'installation utilise un script bash unique qui gère la sélection interactive
	(version, variante) puis lance automatiquement l'installateur approprié. Deux méthodes
	d'installation sont disponibles :
</p>
<ul>
	<li>
		<strong>Méthode "Clean"</strong> (recommandée) : installe la disposition dans un répertoire
		d'extensions dédié (<code>/usr/share/xkeyboard-config.d/ergopti/</code>) sans modifier aucun
		fichier système. Cette méthode nécessite <code>libxkbcommon</code> ≥ 1.13.0 et
		<code>xkeyboard-config</code> ≥ 2.45 (Arch et Fedora récentes la proposent).
	</li>
	<li>
		<strong>Méthode "Legacy"</strong> : modifie directement les fichiers système XKB (<code
			>/usr/share/X11/xkb/</code
		>). Compatible avec toutes les versions, mais moins propre. C'est la méthode qui était utilisée
		historiquement.
	</li>
</ul>
<p>
	Le script de détection choisit automatiquement la méthode optimale selon votre système, puis
	chacune de ses étapes affiche son résultat (plus rien n'est silencieux). Les couches Maj,
	Verr Maj et AltGr sont fournies par un fichier de <em>types</em> désormais <strong>toujours
	inclus</strong> : la couche raccourcis (<kbd>Ctrl</kbd>/<kbd>Alt</kbd>/<kbd>Win</kbd>) rend
	la lettre de base Ergopti de chaque touche — et sur les touches sans lettre simple comme
	<kbd>é</kbd>, <kbd>à</kbd>, <kbd>ê</kbd>, elle rend respectivement <kbd-output>C</kbd-output>,
	<kbd-output>V</kbd-output>, <kbd-output>Z</kbd-output> pour garder Copier/Coller/Annuler sous les
	doigts.
	La réinstallation par-dessus une version précédente (y compris l'ancienne méthode) nettoie
	automatiquement les restes de l'installation antérieure. Enfin, la variante « Ergopti++ » n'est
	plus proposée à l'installation : elle sature la table XCompose ; utilisez Ergopti ou Ergopti+.
</p>
<p>
	Le script demande les droits <code>sudo</code>. Pour désinstaller :
</p>
<code
	style="display:inline-block; width:100%; padding:1em; text-align:left"
	>branch="${branch}"; curl -fsSL
	"https://raw.githubusercontent.com/adrienm7/ergopti/$branch/static/ergopti/linux/xkb_installation/install.sh"
	| BRANCH="$branch" bash -s -- --uninstall</code
>
<div class="download-buttons">
	<a href={urlInstallSh} download="install.sh">
		<button class="alt-button"><i class="icon-linux"></i> Script complet d'installation</button>
	</a>
	<a href={urlDetectSh} download="detect_installation_method.sh">
		<button class="alt-button"><i class="icon-linux"></i> Script de détection de méthode</button>
	</a>
</div>
<div class="download-buttons" style="margin-top: 1em;">
	<a href={urlInstallerClean} download="xkb_files_installer_clean.py">
		<button><i class="icon-linux"></i> Installateur Clean</button>
	</a>
	<a href={urlInstallerLegacy} download="xkb_files_installer_legacy.py">
		<button><i class="icon-linux"></i> Installateur Legacy</button>
	</a>
</div>

<h3>Détails techniques de l'installation</h3>

<h4>Méthode Clean (recommandée)</h4>
<p>Voici un résumé de ce que réalise l'installateur Clean :</p>
<ul>
	<li>
		<strong>Installation non invasive</strong> : crée un répertoire d'extension dans
		<code>/usr/share/xkeyboard-config.d/ergopti/</code>
		contenant les fichiers de définition du layout (symbols, types, règles). Cette méthode ne modifie
		aucun fichier système existant.
	</li>
	<li>
		<strong>.XCompose</strong> : création (ou remplacement s'il existe déjà) du fichier
		<code>.XCompose</code>
		dans le home de l'utilisateur (<code>~/.XCompose</code>). Cela permet d'utiliser les touches
		mortes ainsi que les sorties en plusieurs caractères, comme les ponctuations avec espaces
		insécables automatiques.
	</li>
	<li>
		<strong>Activation</strong> : le script tente d'appliquer la disposition via
		<code>setxkbmap</code> et de purger le cache XKB pour une application immédiate des changements.
	</li>
</ul>

<h4>Méthode Legacy (compatibilité)</h4>
<p>Voici un résumé de ce que réalise l'installateur Legacy :</p>
<ul>
	<li>
		<strong>Sauvegarde</strong> : création d'une copie de sauvegarde pour chaque fichier modifié.
		Par exemple,
		<code>fichier.ext.1</code> est créé comme copie de <code>fichier.ext</code> avant toute modification
		de celui-ci. Ainsi, il sera toujours possible de revenir en arrière si besoin.
	</li>

	<li>
		<strong>XKB Symbols</strong> : ajout (ou mise à jour si elle existe déjà) d'une section
		<code>xkb_symbols "..."</code>
		dans le fichier <code>/usr/share/X11/xkb/symbols/fr</code>. Ces définitions décrivent ce que
		fait chaque touche sur chacune des couches (Shift, CapsLock, AltGr, etc.).
	</li>

	<li>
		<strong>XKB Types</strong> : ajout (ou mise à jour si elles existent déjà) des définitions de
		types personnalisées d'<Ergopti></Ergopti> dans le fichier
		<code>/usr/share/X11/xkb/types/extra</code>. Les types définissent l'association entre le numéro
		de couche défini dans XKB Symbols avec les modificateurs qui doivent être pressés pour atterrir
		sur cette couche.
	</li>

	<li>
		<strong>XKB Rules & Menus</strong> : ajout (ou mise à jour si l'entrée existe déjà) des fichiers
		<code>/usr/share/X11/xkb/rules/evdev.lst</code>
		et
		<code>/usr/share/X11/xkb/rules/evdev.xml</code>. Cela permet de faire apparaître la disposition
		dans la liste des dispositions système, et donc de la sélectionner.
	</li>

	<li>
		<strong>.XCompose</strong> : création (ou remplacement s'il existe déjà) du fichier
		<code>.XCompose</code>
		dans le home de l'utilisateur (<code>~/.XCompose</code>). Cela permet d'utiliser les touches
		mortes ainsi que les sorties en plusieurs caractères, comme les ponctuations avec espaces
		insécables automatiques.
	</li>

	<li>
		<strong>Activation</strong> : enfin, le script tente d'appliquer la disposition : d'abord via
		<code>localectl set-x11-keymap</code> (si disponible), puis via <code>setxkbmap</code> dans la session
		X de l'utilisateur. Ces actions sont « best‑effort » et peuvent échouer sans annuler l'installation.
	</li>
</ul>

<p>
	En bref : la méthode Clean installe dans un répertoire d'extensions sans toucher aux fichiers
	système, tandis que la méthode Legacy modifie directement les fichiers système XKB.
</p>

<h3 id="linux-solutions">Résolution de problèmes connus</h3>
<p>
	Certains problèmes ont été rapportés avec le pilote XKB d'<Ergopti></Ergopti> dans quelques logiciels
	:
</p>
<ul>
	<li>
		Le raccourci <kbd-output>Ctrl+Z</kbd-output> en <kbd>Ctrl</kbd> + <kbd>È</kbd> ne semble pas fonctionner.
		Pourtant, tous les autres raccourcis sur les lettres accentuées fonctionnent, alors qu'ils sont définis
		de la même manière.
	</li>
	<li>
		Sur Wayland, XCompose ne fonctionne pas dans certains programmes. C'est notamment le cas des
		applications Electron comme VSCode. Ce problème implique que les touches mortes ne vont pas
		fonctionner, de même pour les output de plusieurs caractères comme les ponctuations avec espaces
		insécables automatiques. Il existe peut-être des workarounds.
	</li>
	<li>
		Avec la version <ErgoptiPlus></ErgoptiPlus> directement intégrée au driver clavier (« Ergopti++ »),
		il y a les mêmes problèmes que sur cette même version sur macOS. Cela inclut le fait qu'un appui
		sur
		<kbd>Entrée</kbd>
		en état de touche morte envoie la touche morte, mais pas directement
		<kbd-output>Entrée</kbd-output>. Pour cela, il est nécessaire d'appuyer une deuxième fois sur la
		touche. Ce problème peut probablement être résolu en utilisant un autre logiciel de remappage de
		clavier, comme cela a été corrigé sur macOS. <br /> Un autre problème plus embêtant est que la
		répétition de deux lettres ne fonctionne pas, notamment pour la lettre
		<kbd>P</kbd>
		où pour tapper <kbd-output>PP</kbd-output>, il faut appuyer quatre fois sur la touche
		<kbd>P</kbd>. Par conséquent, il est plutôt recommandé d'utiliser la version standard d'<Ergopti
		></Ergopti> ou « Ergopti+ » (un seul +) avec le driver
		<a href="ergopti-plus" class="link"><ErgoptiPlus /></a>.
	</li>
</ul>
