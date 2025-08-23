<script>
	import Nom from '$lib/composants/Nom.svelte';
	import NomPlus from '$lib/composants/NomPlus.svelte';
	import SFB from '$lib/composants/SFB.svelte';
</script>

<h2>Confort</h2>

<h3>
	Touche <kbd>BackSpace</kbd> à la place de <kbd>"RCtrl"</kbd>
</h3>
<p>
	La touche <kbd>BackSpace</kbd> est l’une des touches les plus utilisées sur un clavier. En effet,
	elle permet de corriger une erreur, ce qui est très fréquent lors de la frappe d’un texte.
	Pourtant, sur les claviers standards, elle est extrêmement loin, étant placée en haut à droite du
	clavier. Par conséquent, il est logique de vouloir la placer sur un emplacement très accessible.
	C’est pour cela que la touche <kbd>BackSpace</kbd> a été dupliquée sur la touche
	<kbd>"RCtrl"</kbd> avec <NomPlus />.
</p>
<p>
	La touche <kbd-sortie>Delete</kbd-sortie> se trouve quant à elle sur la combinaison
	<kbd>Shift</kbd> + <kbd>"RCtrl"</kbd>.
</p>
<p>Pour être encore plus rapide, deux raccourcis optionnels ont aussi été implémentés :</p>
<ul>
	<li>
		<kbd>AltGr</kbd> + <kbd>"LAlt"</kbd> ➜ <kbd-sortie>Ctrl</kbd-sortie> +
		<kbd-sortie>BackSpace</kbd-sortie> ;
	</li>
	<li>
		<kbd>AltGr</kbd> + <kbd>"CapsLock"</kbd> ➜ <kbd-sortie>Ctrl</kbd-sortie> +
		<kbd-sortie>Delete</kbd-sortie>.
	</li>
</ul>

<h3>[QU] automatiques avant les voyelles</h3>
<p>
	La touche <kbd>Q</kbd> est 99% du temps suivie de <kbd>U</kbd> si une voyelle vient ensuite. Par
	conséquent, lors de la frappe de <kbd>Q</kbd> + <kbd>Voyelle</kbd>, un <kbd>U</kbd>
	s’intercale automatiquement entre les deux pour donner <kbd-sortie>Q</kbd-sortie> +
	<kbd-sortie>U</kbd-sortie>
	+ <kbd-sortie>Voyelle</kbd-sortie>.
</p>
<p>
	Ainsi, pour écrire <kbd-sortie>QUE</kbd-sortie>, il suffira d’écrire <kbd>QE</kbd>. De même, pour
	écrire <kbd-sortie>POURQUOI</kbd-sortie>, il suffira d’écrire
	<kbd>POURQOI</kbd>.
</p>

<h3>Touche [OÙ]</h3>
<p>
	La touche <kbd>Ù</kbd> n’est utilisée que pour écrire <kbd-sortie>OÙ</kbd-sortie>. Ainsi, autant
	transformer cette touche en raccourci pour écrire <kbd-sortie>OÙ</kbd-sortie> afin d’économiser
	une frappe certaine sur la touche <kbd>O</kbd> et améliorer l’alternance des mains.
</p>
<p>
	Ainsi, le <kbd-sortie>Ù</kbd-sortie> en <kbd>AltGr</kbd> + <kbd>W</kbd> se transforme en
	<kbd-sortie>OÙ</kbd-sortie>
	si <NomPlus></NomPlus> est activé.
</p>

<h3>
	<kbd>Ê</kbd> fait office de <kbd class="morte">◌̂</kbd>
</h3>

<p>
	La touche morte <kbd class="morte">◌̂</kbd> est utilisée la majorité du temps suivie de
	<kbd>E</kbd> afin d’écrire <kbd-sortie>Ê</kbd-sortie>. C’est pour cela qu’une touche <kbd>Ê</kbd>
	a été placée sur l’auriculaire gauche afin d’éviter un appui sur deux touches pour cette lettre circonflexe
	très commune.
</p>
<p>
	Toutefois, dans de rares cas, il est nécessaire d’écrire <kbd>Â</kbd>,
	<kbd>Î</kbd>, <kbd>Ô</kbd> ou encore <kbd>Û</kbd>. C’est pour cela que <kbd>ÊA</kbd> va donner
	<kbd-sortie>Â</kbd-sortie>, <kbd>ÊI</kbd> va donner <kbd-sortie>Î</kbd-sortie>, etc. Cela permet
	de ne plus du tout avoir à utiliser la touche morte <kbd class="morte">◌̂</kbd>, et donc bouger
	encore moins les mains.
</p>
<mini-espace></mini-espace>
<p>
	Les plus attentifs d’entre vous remarqueront que l’écriture de <kbd-sortie>Â</kbd-sortie> et de
	<kbd-sortie>AÎ</kbd-sortie>
	(par exemple pour écrire « paraît ») engendre des <SFB></SFB>s avec cette nouvelle méthode. C’est
	pour cela qu’il est aussi possible de réaliser <kbd>ÉÊ</kbd> pour obtenir
	<kbd-sortie>Â</kbd-sortie>
	et <kbd>ÊÉ</kbd> pour <kbd-sortie>AÎ</kbd-sortie>. Ces options offrent en outre des roulements
	extrêmement confortables sur des bigrammes qui n’existent pas et donc ne posent aucun problème.
</p>
<p>
	En outre, le mécanisme de correction automatique de <NomPlus /> permet de donner
	<kbd-sortie>paraît</kbd-sortie>
	lors de l’écriture de <kbd>parait</kbd>, rendant ce <SFB /> encore plus inoffensif.
</p>

<h3>
	Remplacement automatique des <kbd>'</kbd> par <kbd>’</kbd>
</h3>
<p>
	Lorsqu’on écrit en français ou anglais, il faudrait idéalement utiliser l’apostrophe typographique
	plutôt que l’apostrophe droite. C’est pour cela que <NomPlus /> va automatiquement l’utiliser à la
	place de l’apostrophe droite lors de l’écriture de texte. Cette apostrophe est d’ailleurs plus jolie
	et présente l’avantage de ne pas avoir à être échappée en programmation si une chaîne de caractères
	est écrite avec ce caractère à l’intérieur. Il n’y a pas à réfléchir, il suffit d’écrire normalement
	et l’apostrophe typographique apparaîtra. Les faux positifs devraient être extrêmement rares.
</p>
<p>
	Un autre raccourci a aussi été ajouté pour avoir la possibilité d’écrire <kbd-sortie
		>N'T</kbd-sortie
	>
	par un roulement. Effectivement, <kbd>NT'</kbd> se transforme en
	<kbd-sortie>N'T</kbd-sortie> pour pouvoir faire [majeur, annulaire, auriculaire] plutôt que
	[majeur, auriculaire, annulaire]. Ce raccourci est utile pour réaliser les négations en anglais
	telles que <kbd-sortie>don't</kbd-sortie>, <kbd-sortie>won't</kbd-sortie> ou
	<kbd-sortie>can't</kbd-sortie>.
</p>

<h3>
	Utilisation de la touche <kbd>,</kbd> + <kbd>voyelle</kbd> en tant que <kbd>j</kbd>
</h3>
<p>
	La touche <kbd>j</kbd> minuscule se fait remplacer par <kbd>★</kbd> avec <NomPlus></NomPlus>.
	Cette nouvelle touche possède plusieurs fonctionnalités extrêmement utiles qui seront détaillées
	par la suite. Toutefois, elle prend la place du <kbd>j</kbd> et il convient donc de replacer ce
	caractère autre part. Il convient de noter que seul le caractère <kbd-sortie>j</kbd-sortie> change
	de place, la touche <kbd>J/★</kbd> reste une touche <kbd>J</kbd> dans tous les autres cas, que ce
	soit pour les raccourcis avec <kbd>Ctrl</kbd> (<kbd-sortie>Ctrl</kbd-sortie> +
	<kbd-sortie>J</kbd-sortie>), avec <kbd>Alt</kbd> (<kbd-sortie>Alt</kbd-sortie> +
	<kbd-sortie>J</kbd-sortie>), ou simplement les caractères en <kbd>AltGr</kbd> (<kbd-sortie
		>"</kbd-sortie
	>) ou en <kbd>Shift</kbd>
	(<kbd-sortie>J</kbd-sortie>).
</p>
<p>
	La touche <kbd>,</kbd> est alors utilisée pour réaliser cette substitution, celle-ci étant sur le
	même doigt que l’ancienne touche <kbd>J</kbd> et juste à côté de son ancien emplacement. Les
	combinaisons <kbd>,i</kbd>, <kbd>,e</kbd>, etc. n’existent pas en français. En réalité, la lettre
	<kbd>,</kbd> est systématiquement suivie d’un espace. Cela fournit une formidable opportunité
	d’utiliser cette touche comme un <kbd-sortie>j</kbd-sortie> lorsqu’elle est suivie d’une voyelle,
	et donc de remplacer efficacement la touche <kbd>j</kbd>.
</p>
<p>
	Dans les rares cas où l’on souhaite écrire <kbd>j</kbd> + <kbd>consonne</kbd>, il est possible
	d’écrire par exemple <kbd>ja</kbd> et de supprimer la voyelle. Une autre possibilité est de
	réaliser la suite de touches <kbd>,</kbd> + <kbd>à</kbd> qui donne la lettre
	<kbd-sortie>j</kbd-sortie>. Dernière possibilité, <kbd-sortie>j</kbd-sortie> est aussi présente
	nativement en <kbd>Shift</kbd> + <kbd>AltGr</kbd> + <kbd>J/★</kbd>. En fait, on pourrait même
	toujours utiliser cet emplacement en <kbd>Shift</kbd> + <kbd>AltGr</kbd> sans utiliser l’astuce de
	la touche <kbd>,</kbd>, mais utiliser cette dernière permet une frappe plus rapide et plus fluide,
	car il suffit de taper sur <kbd>,</kbd> et non d’activer plusieurs modificateurs en même temps.
</p>

<p class="text-bold">En résumé :</p>
<ul class="margin-top-2">
	<li><kbd>,a</kbd> ➜ <kbd-sortie>ja</kbd-sortie> ;</li>
	<li><kbd>,i</kbd> ➜ <kbd-sortie>ji</kbd-sortie> ;</li>
	<li><kbd>,e</kbd> ➜ <kbd-sortie>je</kbd-sortie> ;</li>
	<li><kbd>,é</kbd> ➜ <kbd-sortie>jé</kbd-sortie> ;</li>
	<li><kbd>,o</kbd> ➜ <kbd-sortie>jo</kbd-sortie> ;</li>
	<li><kbd>,u</kbd> ➜ <kbd-sortie>ju</kbd-sortie> ;</li>
	<li><kbd>,ê</kbd> ➜ <kbd-sortie>ju</kbd-sortie> pour éviter un <SFB /> ;</li>
	<li><kbd>,'</kbd> ➜ <kbd-sortie>j’</kbd-sortie> ;</li>
	<li><kbd>,à</kbd> ➜ <kbd-sortie>j</kbd-sortie> ;</li>
	<li><kbd>Shift</kbd> + <kbd>J/★</kbd> ➜ <kbd-sortie>J</kbd-sortie> ;</li>
	<li><kbd>Shift</kbd> + <kbd>AltGr</kbd> + <kbd>J/★</kbd> ➜ <kbd-sortie>j</kbd-sortie>.</li>
</ul>

<p>
	L’avantage de ce choix en <kbd>,</kbd> est aussi que contrairement à une touche morte, il n’y a
	pas besoin ici de frapper sur deux touches pour n’en donner qu’une seule. Nul besoin de taper sur
	<kbd class="morte">touche morte</kbd> + <kbd class="morte">j sur la touche morte</kbd> +
	<kbd>voyelle</kbd>. Il suffit de faire <kbd>,</kbd> + <kbd>voyelle</kbd>. Ainsi, la frappe n’est
	absolument pas ralentie, car on ne rajoute pas de touches supplémentaires à taper.
</p>
