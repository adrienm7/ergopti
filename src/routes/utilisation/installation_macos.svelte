<script>
	import Ergopti from '$lib/components/Ergopti.svelte';
	import ErgoptiPlus from '$lib/components/ErgoptiPlus.svelte';
	import SFB from '$lib/components/SFB.svelte';
	import { version } from '$lib/stores_infos.js';
	import { getLatestVersion } from '$lib/js/getVersions.js';
	let versionValue, version_mineure_macos;
	version.subscribe((value) => {
		versionValue = value;
		version_mineure_macos = getLatestVersion('macos_keylayout', versionValue);
	});
</script>

<h2 id="macos">
	<i class="icon-appleinc purple" style="font-size:0.8em; vertical-align:0; margin-right:0.25em"
	></i>Installation macOS
</h2>
<tiny-space></tiny-space>
<div class="download-buttons">
	{#if version_mineure_macos !== undefined}
		<a
			href="/drivers/macos/bundles/zipped_bundles/Ergopti_v{version_mineure_macos}.bundle.zip"
			download
		>
			<button
				><i class="icon-appleinc" style="font-size:0.8em; vertical-align:0"></i>
				Ergopti v{version_mineure_macos}.bundle</button
			>
		</a>
	{/if}
</div>

<tiny-space></tiny-space>

<p>Ce bundle doit être dézippé puis placé dans le dossier des extensions de clavier de macOS :</p>
<code>/Library/Keyboard Layouts/</code>

<p>
	Il est également possible de l’installer sans droits d’administrateur en plaçant le bundle dans le
	dossier utilisateur :
</p>
<code>~/Library/Keyboard Layouts/</code>

<p>
	Pour naviguer rapidement vers ce chemin, il existe le raccourci <kbd>Cmd</kbd> + <kbd>Shift</kbd>
	+ <kbd>G</kbd> dans le Finder. Cela ouvre directement l'emplacement spécifié.
</p>

<tiny-space></tiny-space>

<p>
	Après avoir placé le bundle dans le bon dossier, redémarrer la session (ou l’ordinateur) pour que
	macOS prenne en compte la nouvelle disposition. Ensuite, aller dans <code
		>Préférences Système</code
	>
	> <code>Clavier</code>
	> <code>Méthodes de saisie</code> > <code>Modifier…</code> et ajouter une disposition en appuyant
	sur <code>+</code> en bas à gauche. Généralement, la disposition se trouvera dans la section « Français »,
	mais elle peut aussi parfois se trouver dans « Autres ».
</p>
<enhanced:img
	src="$lib/images/macos_installation_1.jpg"
	alt="Screenshot 1/4 des paramètres macOS pour changer sa disposition de clavier"
/>
<div style="margin-top:15px"></div>
<enhanced:img
	src="$lib/images/macos_installation_2.jpg"
	alt="Screenshot 2/4 des paramètres macOS pour changer sa disposition de clavier"
/>
<div style="margin-top:15px"></div>
<enhanced:img
	src="$lib/images/macos_installation_3.jpg"
	alt="Screenshot 3/4 des paramètres macOS pour changer sa disposition de clavier"
/>
<div style="margin-top:15px"></div>
<enhanced:img
	src="$lib/images/macos_installation_4.jpg"
	alt="Screenshot 4/4 des paramètres macOS pour changer sa disposition de clavier"
/>
<div style="margin-top:15px"></div>
<p>La disposition pourra ensuite être sélectionnée depuis la barre des tâches :</p>
<enhanced:img
	src="$lib/images/macos_language_bar.jpg"
	alt="Screenshot de la sélection de clavier dans la barre des tâches"
/>
<div style="margin-top:15px"></div>

<tiny-space></tiny-space>

<p>Le bundle contient plusieurs variantes de la disposition :</p>
<ul>
	<li><strong>Ergopti</strong> : version standard, la même que le KbdEdit sur Windows ;</li>
	<li>
		<strong>Ergopti+</strong> : version standard incluant la touche <kbd-output>★</kbd-output> à la
		place de
		<kbd>J</kbd>
		ainsi que les petites modifications en
		<kbd>AltGr</kbd> (<kbd-output>%</kbd-output> à la place de <kbd>œ</kbd>,
		<kbd-output>!</kbd-output>
		à la place de <kbd>ç</kbd>, etc.) ;
	</li>
	<li>
		<strong>Ergopti++</strong> : Ergopti+ avec l’ajout de nombreuses touches mortes pour avoir
		directement les roulements personnalisés dans le keylayout ;
	</li>
</ul>
<p>
	<strong>Ergopti++</strong> permet de rapidement tester les roulements personnalisés comme
	<kbd>hc</kbd>
	donnant <kbd-output>wh</kbd-output> ou encore <kbd>(#</kbd> donnant <kbd-output>("</kbd-output>.
	Toutefois, elle entraîne certains petits problèmes. Parmi ceux-ci, il y a le fait qu’il faut
	appuyer 2 fois sur <kbd>Entrée</kbd> pour valider la touche morte et envoyer
	<kbd-output>Entrée</kbd-output>. Les touches mortes ne fonctionnent pas non plus sur l’écran de
	verrouillage, ce qui peut carrément empêcher la saisie de son mot de passe. Enfin, la fermeture
	automatique des parenthèses ne fonctionne pas dans les éditeurs de code. Pour toutes ces raisons,
	il est donc conseillé de plutôt utiliser <strong>Ergopti+</strong> avec Karabiner pour y définir ces
	roulements.
</p>
<p>
	Des <strong>variantes ANSI</strong> de ces dispositions sont également disponibles. En effet, sur
	macOS, un clavier ANSI entraîne de petites différences dans l’arrangement des codes de touches. Si
	aucun pilote dédié n’était disponible, le <kbd>ê</kbd> se verrait être échangé de place avec le
	<kbd>$</kbd>
	de la rangée des chiffres. En outre, la touche morte <kbd class="deadkey">◌̂</kbd> se verrait être
	échangée avec
	<kbd class="deadkey">◌̈</kbd> et donc être encore moins accessible.
</p>

<h3 id="macos-solutions">Résolution de problèmes connus</h3>
<p>
	Certains problèmes ont été rapportés avec le keylayout d’<Ergopti></Ergopti> dans quelques logiciels :
</p>
<ul>
	<!-- <li>
		Databricks (sur navigateur) : Taper un <kbd>_</kbd> avec <kbd>AltGr</kbd> + <kbd>␣</kbd> n’est pas
		possible, la combinaison est bloquée, probablement pour être utilisée par un raccourci interne. Il
		n’y a pas de solution connue pour l’instant.
	</li> -->
	<li>
		Les touches mortes suivies d’<kbd>Entrée</kbd> nécessitent un double appui sur
		<kbd>Entrée</kbd>. En effet, il faut un premier appui pour valider la touche morte, puis un
		second appui pour envoyer <kbd>Entrée</kbd>. Ce problème peut se résoudre avec Karabiner, en
		envoyant un appui "inutile" lors d’un appui sur <kbd>Entrée</kbd>. Par exemple en envoyant un
		appui sur <kbd-output>F20</kbd-output> puis un appui sur <kbd-output>Entrée</kbd-output> lors de
		l’appui sur <kbd>Entrée</kbd>.
	</li>
	<li>
		Les touches mortes ne fonctionnent pas sur l’écran de verrouillage, ni les touches envoyant plus
		d’un caractère d’un coup, comme <kbd><nbsp></nbsp>:</kbd>. Ce problème cause surtout des
		difficultés avec ErgoptiPlus qui contient beaucoup de nouvelles touches mortes. Le keylayout
		Ergopti standard ne présente pas ce problème n’ayant que des touches mortes simples.
	</li>
	<li>
		Parfois, Ergopti peut ne pas s’afficher dans la liste des dispositions clavier. Pour résoudre ce
		problème, extraire le fichier keylayout du bundle et le placer dans le même dossier que celui-ci
		(en supprimant le bundle, pour ne pas avoir de doublon d’ids). Le bundle n’est qu’un moyen un
		peu plus complexe d’installer des fichiers keylayouts, en permettant d’ajouter une traduction
		des noms, installer plusieurs variantes d’un coup, etc. <br />Si, après redémarrage, Ergopti ne
		s’affiche pas dans « Autres », alors c’est que le keylayout pose problème. C’est grâce au bundle
		que la disposition peut s’afficher dans la catégorie « Français », ici il est certain que la
		disposition sera dans « Autres » si elle est reconnue.
		<br />
		En dernier recours, on peut essayer d’ouvrir le keylayout avec le logiciel Ukulele, pour vérifier
		sa validité. Il est aussi possible de le modifier directement avec un éditeur de texte, car il s’agit
		d’un simple fichier XML.
		<br />
		Ce problème ne devrait cependant a priori jamais exister, car le fichier keylayout est toujours testé
		avant d’être partagé. Ces tests sont à la fois manuels et automatisés par de nombreux tests unitaires
		Python.
	</li>
	<enhanced:img src="$lib/images/macos_open_bundle.jpg" alt="Ouverture du bundle" />
</ul>

<h3>
	<i class="icon-karabiner" style="font-size:0.8em; vertical-align:0; margin-right:0.25em"
	></i>Karabiner
</h3>

<p class="encadre">
	<b>Attention :</b> Le code Karabiner suivant est encore en bêta et risque d’être régulièrement mis
	à jour. Il est totalement fonctionnel, mais des améliorations et ajouts sont encore possibles. Veillez
	à vérifier régulièrement si une nouvelle version est disponible.
</p>

<tiny-space></tiny-space>

<div class="download-buttons">
	<a href="/drivers/karabiner/karabiner.json" target="_blank">
		<button
			><i class="icon-karabiner" style="font-size:0.8em; vertical-align:0; margin-right:0.25em"></i>
			karabiner.json</button
		>
	</a>
</div>
<p>
	<a href="https://karabiner-elements.pqrs.org/" class="link">Karabiner-Elements</a> est un logiciel
	open source permettant de remapper les touches sur macOS. Il est particulièrement utile avec la
	disposition <ErgoptiPlus></ErgoptiPlus> pour ajouter des tap-holds, définir des roulements personnalisés,
	etc. Voici ce qui est inclus dans le fichier de configuration fourni :
</p>
<ul>
	<li>
		Interversion des touches <kbd>ROption</kbd> et <kbd>RCmd</kbd> pour avoir la couche
		<kbd-output>AltGr</kbd-output> aussi facilement accessible que sur Windows ;
	</li>
	<li>
		Tap-hold sur <kbd>CapsLock</kbd> avec <kbd-output>Entrée</kbd-output> en tap et
		<kbd-output>Cmd</kbd-output> en hold ;
	</li>
	<li>
		Tap-hold sur <kbd>ROption</kbd> (intervertie en <kbd>RCmd</kbd>) avec
		<kbd-output>One-Shot Shift</kbd-output>
		en tap et
		<kbd-output>Shift</kbd-output> en hold ;
	</li>
	<li>
		Tap-hold sur <kbd>LShift</kbd> avec <kbd-output>Copier</kbd-output> en tap ;
	</li>
	<li>
		Tap-hold sur <kbd>Fn</kbd> avec <kbd-output>Coller</kbd-output> en tap ;
	</li>
	<li>
		Tap-hold sur <kbd>LCtrl</kbd> avec <kbd-output>Couper</kbd-output> en tap ;
	</li>
	<li>
		Tap-hold sur <kbd>LOption</kbd> avec <kbd-output>BackSpace</kbd-output> en tap ;
	</li>
	<li>
		Définition de tous les roulements personnalisés d’Ergopti++ comme
		<kbd>hc</kbd> → <kbd-output>wh</kbd-output>, <kbd>qa</kbd> → <kbd-output>qua</kbd-output>,
		<kbd>(#</kbd>
		→ <kbd-output>("</kbd-output>, etc. ;
	</li>
</ul>
<p>
	À noter que le code Karabiner est loin d'être concis, car beaucoup de lignes n’ont qu’une seule
	accolade ouvrante ou fermante. Ainsi, pour définir un seul comportement, des dizaines de lignes
	sont nécessaires. En outre, afin de définir les roulements personnalisés, il était nécessaire
	d’avoir l’information de la dernière touche pressée, ce qui n’est pas disponible par défaut dans
	Karabiner. C’est pour cela que chaque touche du clavier a été redéfinie pour envoyer le contenu de
	sa touche, mais aussi mettre à jour une variable contenant la dernière touche pressée. Tout cela
	entraîne un code Karabiner extrêmement volumineux (des dizaines de milliers de lignes) pour un
	comportement pourtant très simple. Cela n’a cependant jamais posé de problème en pratique, ni de
	performances.
</p>

<h3>
	<i class="icon-hammerspoon" style="font-size:0.8em; vertical-align:0; margin-right:0.25em"
		><span class="icon-hammerspoon"><span class="path1"></span><span class="path2"></span></span></i
	>Hammerspoon
</h3>

<p class="encadre">
	<b>Attention :</b> Le code Hammerspoon suivant est encore en bêta et risque d'être régulièrement mis
	à jour. Il est totalement fonctionnel, mais des améliorations et ajouts sont encore possibles. Veillez
	à vérifier régulièrement si une nouvelle version est disponible.
</p>

<tiny-space></tiny-space>

<div class="download-buttons">
	<a href="/drivers/hammerspoon/init.lua" target="_blank">
		<button
			><i class="icon-hammerspoon" style="font-size:0.8em; vertical-align:0; margin-right:0.25em"
				><span class="icon-hammerspoon"><span class="path1"></span><span class="path2"></span></span
				></i
			>
			init.lua</button
		>
	</a>
</div>

<p>
	<a href="https://www.hammerspoon.org/" target="_blank" class="link">Hammerspoon</a> est un outil d'automatisation
	puissant et open source pour macOS, permettant d'interagir avec le système via des scripts Lua. Il
	est particulièrement utile pour définir des gestes personnalisés sur le trackpad et ajouter des fonctionnalités
	avancées. Voici ce qui est inclus dans le fichier de configuration fourni :
</p>
<ul>
	<li>
		<strong>Gestes à trois doigts :</strong> Utilisation de swipes à trois doigts pour la navigation
		dans les onglets :
		<ul>
			<li>Swipe gauche/droite : Changer d'onglet (<kbd>Ctrl</kbd> + <kbd>Tab</kbd>) ;</li>
			<li>Swipe haut : Ouvrir un nouvel onglet (<kbd>Cmd</kbd> + <kbd>T</kbd>) ;</li>
			<li>Swipe bas : Fermer l'onglet actuel (<kbd>Cmd</kbd> + <kbd>W</kbd>).</li>
		</ul>
	</li>
	<li>
		<strong>Tap à trois doigts :</strong> Basculer en mode sélection pour faire glisser le curseur et
		sélectionner du texte sans maintenir de bouton physique enfoncé. Un second tap ou clic désactive
		ce mode.
	</li>
	<li>
		<strong>Zoom avec scroll :</strong> Maintenir <kbd>Cmd</kbd> et utiliser le scroll pour zoomer (<kbd
			>Cmd</kbd
		>
		+ <kbd>+</kbd>) ou dézoomer (<kbd>Cmd</kbd> + <kbd>-</kbd>).
	</li>
</ul>

<p>
	Le fichier de configuration nécessite également le Spoon <strong>Swipe.spoon</strong> qui est fourni
	dans le dossier. Pour installer Hammerspoon et cette configuration :
</p>
<ol>
	<li>
		Télécharger et installer <a href="https://www.hammerspoon.org/" target="_blank" class="link"
			>Hammerspoon</a
		> ;
	</li>
	<li>Copier le fichier <code>init.lua</code> dans <code>~/.hammerspoon/</code> ;</li>
	<li>
		Copier le dossier <code>Spoons/</code> (contenant Swipe.spoon) dans
		<code>~/.hammerspoon/Spoons/</code> ;
	</li>
	<li>Recharger la configuration Hammerspoon depuis l'icône dans la barre de menu.</li>
</ol>

<p>
	<strong>Note :</strong> Pour éviter les conflits avec les gestes système de macOS, il est
	recommandé d'aller dans <code>Réglages Système</code> > <code>Trackpad</code> >
	<code>Plus de gestes</code>
	et de :
</p>
<ul>
	<li>
		Configurer <code>Balayer entre les apps en plein écran</code> avec un nombre de doigts différent
		(par exemple 4) ;
	</li>
	<li>
		Configurer <code>Mission Control</code> avec un nombre de doigts différent (par exemple 4).
	</li>
</ul>

<h3>
	<i class="icon-alfred" style="font-size:0.8em; vertical-align:0; margin-right:0.25em"></i>Alfred
</h3>

<p class="encadre">
	<b>Attention :</b> Le code Alfred suivant est encore en bêta et risque d’être régulièrement mis à jour.
	Il est totalement fonctionnel, mais des améliorations et ajouts sont encore possibles. Veillez à vérifier
	régulièrement si une nouvelle version est disponible.
</p>

<tiny-space></tiny-space>

<div class="download-buttons">
	<a
		href="https://github.com/adrienm7/ergopti/tree/main/static/drivers/alfred/snippets"
		target="_blank"
	>
		<button
			><i class="icon-alfred" style="font-size:0.8em; vertical-align:0; margin-right:0.25em"></i>
			Dossier de snippets Alfred</button
		>
	</a>
	<a
		href="https://github.com/adrienm7/ergopti/tree/main/static/drivers/alfred/workflows"
		target="_blank"
	>
		<button
			><i class="icon-alfred" style="font-size:0.8em; vertical-align:0; margin-right:0.25em"></i>
			Dossier de workflows Alfred</button
		>
	</a>
</div>

<p>
	<a href="https://www.alfredapp.com/" target="_blank" class="link">Alfred</a> est un lanceur
	d’applications et un gestionnaire de snippets pour macOS. Il est possible d’y définir des snippets
	de texte qui seront insérés lorsqu’on tape une abréviation. C’est grâce à ce logiciel que la
	touche <kbd>★</kbd>
	d’<ErgoptiPlus></ErgoptiPlus>
	peut être utilisée comme touche de répétition et pour insérer des snippets, des caractères spéciaux,
	etc.
</p>

<h4>Snippets</h4>
<p>
	Le dossier de snippets fourni contient l’intégralité des snippets d’<ErgoptiPlus></ErgoptiPlus>.
	Ils sont automatiquement extraits du fichier <em>.ahk</em>
	d’<ErgoptiPlus></ErgoptiPlus>. Il suffit d’installer ces snippets dans Alfred pour pouvoir les
	utiliser dans n’importe quelle application. Pour cela, il suffit de cliquer dessus, ce qui ouvrira
	Alfred et proposera de les installer.
</p>
<p>
	Attention, il faut bien penser à désactiver l’option
	<code>Strip snippets from autoexpand</code> lors de chaque import. À noter aussi que les snippets dans
	Alfred sont une fonctionnalité payante, disponible uniquement avec la licence Powerpack. Alfred semble
	être le meilleur gestionnaire de snippets sur macOS, les alternatives gratuites ne fonctionnant malheureusement
	pas aussi bien, étant notamment trop "lentes" à l’utilisation.
</p>

<h4>Workflows</h4>
<p>
	Plusieurs workflows Alfred sont fournis pour reproduire les raccourcis Windows (<kbd>Win</kbd> +
	touche) en utilisant <kbd>Ctrl</kbd> + touche sur macOS. Seul cas particulier : <kbd>Ctrl</kbd> +
	<kbd>H</kbd>
	pour la capture d'écran, car <kbd>Ctrl</kbd> + <kbd>C</kbd> est déjà utilisé pour stopper un processus
	dans le terminal.
</p>
<p>
	Pour installer ces workflows, il suffit de double-cliquer sur les fichiers
	<code>.alfredworkflow</code>, ce qui ouvrira Alfred et proposera de les importer. Ces workflows
	nécessitent la licence Powerpack d'Alfred.
</p>
