<script>
	import Ergopti from '$lib/components/Ergopti.svelte';
	import SFB from '$lib/components/SFB.svelte';
	import { version } from '$lib/stores_infos.js';
	import { getLatestVersion } from '$lib/js/getVersions.js';
	let versionValue, version_mineure_kbdedit_mac;
	version.subscribe((value) => {
		versionValue = value;
		version_mineure_kbdedit_mac = getLatestVersion('kbdedit_mac', versionValue);
	});
</script>

<h2 id="macos">
	<i class="icon-appleinc purple" style="font-size:0.8em; vertical-align:0; margin-right:0.25em"
	></i>Installation macOS
</h2>
<tiny-space></tiny-space>
<div>
	{#if version_mineure_kbdedit_mac !== undefined}
		<a href="/drivers/macos/Ergopti_v{version_mineure_kbdedit_mac}.bundle.zip" download>
			<button
				><i class="icon-appleinc" style="font-size:0.8em; vertical-align:0"></i>
				Ergopti_v{version_mineure_kbdedit_mac}.bundle</button
			>
		</a>
	{/if}
</div>
<p>Ce bundle doit être dézippé puis placé dans le dossier des extensions de clavier de macOS :</p>
<code>/Library/Keyboard Layouts/</code>

<p>
	Il est aussi possible de l’installer sans droits d’administrateur en plaçant le bundle dans le
	dossier utilisateur :
</p>
<code>~/Library/Keyboard Layouts/</code>

<br />
<p>
	Après avoir placé le bundle dans le bon dossier, redémarrer la session (ou l’ordinateur) pour que
	macOS prenne en compte la nouvelle disposition. Ensuite, aller dans Préférences Système ➜ Clavier
	➜ Méthodes de saisie et ajouter la disposition Ergopti. Généralement, la disposition se trouvera
	dans la section « Français », mais elle peut aussi parfois se trouver dans « Autres ».
</p>

<h3>Résolution de problèmes connus</h3>
<p>Certains problèmes ont été rapportés avec le keylayout d’Ergopti dans quelques logiciels :</p>
<ul>
	<li>
		Databricks (sur navigateur) : Taper un <kbd>_</kbd> avec <kbd>AltGr</kbd> + <kbd>␣</kbd> n’est pas
		possible, la combinaison est bloquée, probablement pour être utilisée par un raccourci interne. Il
		n’y a pas de solution connue pour l’instant.
	</li>
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
</ul>
