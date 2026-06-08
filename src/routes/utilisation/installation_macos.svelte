<script>
	import { onMount } from 'svelte';
	import Ergopti from '$lib/components/Ergopti.svelte';
	import ErgoptiPlus from '$lib/components/ErgoptiPlus.svelte';
	import { getRelease } from '$lib/js/getGitHubRelease.js';

	/** @type {Awaited<ReturnType<typeof getRelease>>} */
	let release = null;
	$: tag = release?.tag?.replace(/^v/, '') ?? '…';
	$: urlMacosBundle = release?.url('Ergopti_macOS.zip') ?? '#';

	onMount(async () => {
		release = await getRelease();
	});
</script>

<h2 id="macos">
	<i class="icon-appleinc purple" style="font-size:0.8em; vertical-align:0; margin-right:0.25em"
	></i>Installation macOS
</h2>
<tiny-space></tiny-space>
<div class="download-buttons">
	<a href={urlMacosBundle} download={!!release}>
		<button disabled={!release}
			><i class="icon-appleinc" style="font-size:0.8em; vertical-align:0"></i>
			Ergopti {tag}.bundle</button
		>
	</a>
</div>

<tiny-space></tiny-space>

<p>Ce bundle doit être dézippé puis placé dans le dossier des extensions de clavier de macOS :</p>
<code>/Library/Keyboard Layouts/</code>

<p>
	Il est également possible de l'installer sans droits d'administrateur en plaçant le bundle dans le
	dossier utilisateur :
</p>
<code>~/Library/Keyboard Layouts/</code>

<p>
	Pour naviguer rapidement vers ce chemin, il existe le raccourci <kbd>Cmd</kbd> + <kbd>Shift</kbd>
	+ <kbd>G</kbd> dans le Finder. Cela ouvre directement l'emplacement spécifié.
</p>

<tiny-space></tiny-space>

<p>
	Après avoir placé le bundle dans le bon dossier, redémarrer la session (ou l'ordinateur) pour que
	macOS prenne en compte la nouvelle disposition. Ensuite, aller dans <code
		>Préférences Système</code
	>
	> <code>Clavier</code>
	> <code>Méthodes de saisie</code> > <code>Modifier…</code> et ajouter une disposition en appuyant
	sur <code>+</code> en bas à gauche. Généralement, la disposition se trouvera dans la section « Français
	», mais elle peut aussi parfois se trouver dans « Autres ».
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
<p>La disposition pourra ensuite être sélectionnée depuis la barre des tâches :</p>
<enhanced:img
	src="$lib/images/macos_language_bar.jpg"
	alt="Screenshot de la sélection de clavier dans la barre des tâches"
/>
<div style="margin-top:15px"></div>

<tiny-space></tiny-space>

<p>Le bundle contient plusieurs variantes de la disposition :</p>
<ul>
	<li><strong>Ergopti</strong> : version standard, la même que le KbdEdit sur Windows ;</li>
	<li>
		<strong>Ergopti+</strong> : version standard incluant la touche <kbd-output>★</kbd-output> à la
		place de
		<kbd>J</kbd>
		ainsi que les petites modifications en
		<kbd>AltGr</kbd> (<kbd-output>%</kbd-output> à la place de <kbd>œ</kbd>,
		<kbd-output>!</kbd-output>
		à la place de <kbd>ç</kbd>, etc.) ;
	</li>
	<li>
		<strong>Ergopti++</strong> : Ergopti+ avec l'ajout de nombreuses touches mortes pour avoir directement
		les roulements personnalisés dans le keylayout ;
	</li>
</ul>
<p>
	<strong>Ergopti++</strong> permet de rapidement tester les roulements personnalisés comme
	<kbd>hc</kbd>
	donnant <kbd-output>wh</kbd-output> ou encore <kbd>(#</kbd> donnant <kbd-output>("</kbd-output>.
	Toutefois, elle entraîne certains petits problèmes. Parmi ceux-ci, il y a le fait qu'il faut
	appuyer 2 fois sur <kbd>Entrée</kbd> pour valider la touche morte et envoyer
	<kbd-output>Entrée</kbd-output>. Les touches mortes ne fonctionnent pas non plus sur l'écran de
	verrouillage, ce qui peut carrément empêcher la saisie de son mot de passe. Enfin, la fermeture
	automatique des parenthèses ne fonctionne pas dans les éditeurs de code. Pour toutes ces raisons,
	il est donc conseillé de plutôt utiliser <strong>Ergopti+</strong> avec le driver
	<a href="ergopti-plus" class="link"><ErgoptiPlus /></a> pour y définir ces roulements.
</p>
<p>
	Des <strong>variantes ANSI</strong> de ces dispositions sont également disponibles. En effet, sur
	macOS, un clavier ANSI entraîne de petites différences dans l'arrangement des codes de touches. Si
	aucun pilote dédié n'était disponible, le <kbd>ê</kbd> se verrait être échangé de place avec le
	<kbd>$</kbd>
	de la rangée des chiffres. En outre, la touche morte <kbd class="deadkey">◌̂</kbd> se verrait être
	échangée avec
	<kbd class="deadkey">◌̈</kbd> et donc être encore moins accessible.
</p>

<h3 id="macos-solutions">Résolution de problèmes connus</h3>
<p>
	Certains problèmes ont été rapportés avec le keylayout d'<Ergopti></Ergopti> dans quelques logiciels
	:
</p>
<ul>
	<!-- <li>
		Databricks (sur navigateur) : Taper un <kbd>_</kbd> avec <kbd>AltGr</kbd> + <kbd>␣</kbd> n'est pas
		possible, la combinaison est bloquée, probablement pour être utilisée par un raccourci interne. Il
		n'y a pas de solution connue pour l'instant.
	</li> -->
	<li>
		Les touches mortes suivies d'<kbd>Entrée</kbd> nécessitent un double appui sur
		<kbd>Entrée</kbd>. En effet, il faut un premier appui pour valider la touche morte, puis un
		second appui pour envoyer <kbd>Entrée</kbd>. Ce problème peut se résoudre avec le driver
		<a href="ergopti-plus" class="link"><ErgoptiPlus /></a>.
	</li>
	<li>
		Les touches mortes ne fonctionnent pas sur l'écran de verrouillage, ni les touches envoyant plus
		d'un caractère d'un coup, comme <kbd><nbsp></nbsp>:</kbd>. Ce problème cause surtout des
		difficultés avec ErgoptiPlus qui contient beaucoup de nouvelles touches mortes. Le keylayout
		Ergopti standard ne présente pas ce problème n'ayant que des touches mortes simples.
	</li>
	<li>
		Parfois, Ergopti peut ne pas s'afficher dans la liste des dispositions clavier. Pour résoudre ce
		problème, extraire le fichier keylayout du bundle et le placer dans le même dossier que celui-ci
		(en supprimant le bundle, pour ne pas avoir de doublon d'ids). Le bundle n'est qu'un moyen un
		peu plus complexe d'installer des fichiers keylayouts, en permettant d'ajouter une traduction
		des noms, installer plusieurs variantes d'un coup, etc. <br />Si, après redémarrage, Ergopti ne
		s'affiche pas dans « Autres », alors c'est que le keylayout pose problème. C'est grâce au bundle
		que la disposition peut s'afficher dans la catégorie « Français », ici il est certain que la
		disposition sera dans « Autres » si elle est reconnue.
		<br />
		En dernier recours, on peut essayer d'ouvrir le keylayout avec le logiciel Ukulele, pour vérifier
		sa validité. Il est aussi possible de le modifier directement avec un éditeur de texte, car il s'agit
		d'un simple fichier XML.
		<br />
		Ce problème ne devrait cependant a priori jamais exister, car le fichier keylayout est toujours testé
		avant d'être partagé. Ces tests sont à la fois manuels et automatisés par de nombreux tests unitaires
		Python.
	</li>
	<enhanced:img src="$lib/images/macos_open_bundle.jpg" alt="Ouverture du bundle" />
</ul>
