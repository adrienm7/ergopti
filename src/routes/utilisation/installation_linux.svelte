<script>
	import Ergopti from '$lib/components/Ergopti.svelte';
	import ErgoptiPlus from '$lib/components/ErgoptiPlus.svelte';
	import { branchForInstall } from '$lib/js/isDev.js';

	const branch = branchForInstall();

	// Keep the copy-paste command valid in POSIX shells and fish.
	const cmd = `curl -fsSL "https://raw.githubusercontent.com/adrienm7/ergopti/${branch}/static/ergopti/linux/xkb_installation/install.sh" | env BRANCH="${branch}" bash`;
	const uninstallCmd = `${cmd} -s -- --uninstall --yes`;
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
		<code>xkeyboard-config</code> ≥ 2.45 (Arch et Fedora récentes la proposent) ainsi qu'une
		<strong>session Wayland</strong> : seul <code>libxkbcommon</code> lit ce répertoire, le serveur
		Xorg compile ses dispositions avec son propre <code>xkbcomp</code> et ne le voit pas.
	</li>
	<li>
		<strong>Méthode "Legacy"</strong> : modifie directement les fichiers système XKB (<code
			>/usr/share/X11/xkb/</code
		>), avec une sauvegarde numérotée de chaque fichier touché. Compatible avec toutes les versions
		et avec les sessions X11 (Xorg), mais moins propre. C'est la méthode qui était utilisée
		historiquement.
	</li>
</ul>
<p>
	Le script de détection choisit automatiquement la méthode optimale selon votre système et votre
	session, puis chacune de ses étapes affiche son résultat (plus rien n'est silencieux). Les couches
	Maj, Verr Maj et AltGr sont fournies par un fichier de <em>types</em> désormais
	<strong>toujours inclus</strong> : la couche raccourcis (<kbd>Ctrl</kbd>/<kbd>Alt</kbd>/<kbd
		>Win</kbd
	>) rend la lettre de base Ergopti de chaque touche — et sur les touches sans lettre simple comme
	<kbd>é</kbd>, <kbd>à</kbd>, <kbd>ê</kbd>, <kbd>è</kbd>, elle rend respectivement
	<kbd-output>C</kbd-output>, <kbd-output>V</kbd-output>, <kbd-output>X</kbd-output>,
	<kbd-output>Z</kbd-output> pour garder Copier/Coller/Couper/Annuler sous les doigts. Après la
	copie des fichiers, l'installeur compile réellement la disposition (seule, puis à côté d'une autre
	disposition comme <code>us</code>) et vérifie que ce type personnalisé est bien présent avant de
	déclarer l'installation réussie. La réinstallation par-dessus une version précédente (y compris
	l'ancienne méthode) nettoie automatiquement les restes de l'installation antérieure. Enfin, la
	variante « Ergopti++ » n'est plus proposée à l'installation : elle sature la table XCompose ;
	utilisez Ergopti ou Ergopti+.
</p>
<p>
	L'activation dans la session s'exécute toujours <strong>sans</strong> <code>sudo</code> : sur
	GNOME (et ses dérivés) la disposition est placée en tête de vos sources de saisie existantes sans
	en retirer aucune, sur KDE Plasma elle est ajoutée en tête de la liste des dispositions, sur une
	session X11 elle est appliquée immédiatement avec <code>setxkbmap</code>. Les compositeurs qui
	gèrent eux-mêmes leur clavier (Hyprland, Sway, niri, river, Wayfire, labwc) n'ont pas de réglage
	commun : l'installeur affiche alors le fragment de configuration exact à coller dans leur fichier.
</p>
<p>
	Le script demande les droits <code>sudo</code>. Pour désinstaller :
</p>
<code style="display:inline-block; width:100%; padding:1em; text-align:left">{uninstallCmd}</code>
<p>
	L'installeur accepte aussi <code>--version v2_2_1</code>, <code>--ansi</code> et le mode
	totalement non interactif (<code>--yes --version … --variant …</code>) pour les installations
	scriptées.
</p>

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
		<strong>.XCompose</strong> : le fichier Compose d'Ergopti est copié dans le paquet et une ligne
		<code>include</code>
		est ajoutée à votre <code>~/.XCompose</code> sans toucher au reste du fichier (elle est retirée à
		la désinstallation). Cela permet d'utiliser les touches mortes ainsi que les sorties en plusieurs
		caractères, comme les ponctuations avec espaces insécables automatiques.
	</li>
	<li>
		<strong>Vérification puis activation</strong> : la disposition est compilée avec
		<code>xkbcli</code> pour prouver que le type personnalisé est chargé, le cache XKB est purgé, puis
		la disposition est activée dans votre session (voir ci-dessus).
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
		types personnalisées d'<Ergopti></Ergopti> <em>à l'intérieur</em> de la section
		<code>xkb_types</code> du fichier <code>/usr/share/X11/xkb/types/extra</code>, que toutes les
		dispositions incluent. Les types définissent l'association entre le numéro de couche défini dans
		XKB Symbols avec les modificateurs qui doivent être pressés pour atterrir sur cette couche.
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
		<strong>Vérification</strong> : la disposition est compilée avec <code>xkbcli</code> et avec
		<code>xkbcomp</code> (le compilateur de Xorg) quand ils sont installés ; si le type personnalisé
		manque, chaque fichier touché est restauré depuis sa sauvegarde et l'installation est annulée.
	</li>
	<li>
		<strong>Activation</strong> : la disposition est activée dans votre session (voir ci-dessus)
		sous l'identifiant <code>fr</code> + variante <code>Ergopti_vX_Y_Z</code>. Sur une session X11
		sans gestionnaire de disposition, l'installeur indique la commande
		<code>localectl set-x11-keymap</code> qui la rend permanente.
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
