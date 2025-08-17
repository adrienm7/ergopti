<script>
	import Nom from '$lib/composants/Nom.svelte';
	import NomPlus from '$lib/composants/NomPlus.svelte';
	import SFB from '$lib/composants/SFB.svelte';

	import BlocClavier from '$lib/clavier/BlocClavier.svelte';
</script>

<h2>Abréviations</h2>
<h3>Remplacement de texte avec <kbd>★</kbd></h3>
<p>
	Le comportement par défaut de la touche <kbd>★</kbd> est de répéter dernière touche tapée.
	Cependant, dans le cas où une abréviation terminant par cette touche existe dans la liste
	d’abréviations, alors celle-ci sera renvoyée à la place. Ainsi,
	<kbd>r★</kbd>
	envoie le raccourci <kbd-sortie>rien</kbd-sortie>, tandis que <kbd>AR★IVER</kbd> enverra
	<kbd-sortie>ARRIVER</kbd-sortie>. De même, <kbd>AV★</kbd> enverra <kbd-sortie>AVV</kbd-sortie>
	et <kbd>AVV★</kbd> enverra <kbd-sortie>AVEZ-VOUS</kbd-sortie>.
</p>
<mini-espace />
<p class="text-bold">Liste de quelques-unes des abréviations (liste modifiable par vos soins) :</p>
<ul>
	<li><kbd>A★</kbd> ➜ <kbd-sortie>AINSI</kbd-sortie> ;</li>
	<li><kbd>AVV★</kbd> ➜ <kbd-sortie>AVEZ-VOUS</kbd-sortie> ;</li>
	<li><kbd>C★</kbd> ➜ <kbd-sortie>C’EST</kbd-sortie> ;</li>
	<li><kbd>CT★</kbd> ➜ <kbd-sortie>C’ÉTAIT</kbd-sortie> ;</li>
	<li><kbd>DÉ★</kbd> ➜ <kbd-sortie>DÉJÀ</kbd-sortie> ;</li>
	<li><kbd>Ê★</kbd> ➜ <kbd-sortie>ÊTRE</kbd-sortie> ;</li>
	<li><kbd>EEF★</kbd> ➜ <kbd-sortie>EN EFFET</kbd-sortie> ;</li>
	<li><kbd>F★</kbd> ➜ <kbd-sortie>FAIRE</kbd-sortie> ;</li>
	<li><kbd>G★</kbd> ➜ <kbd-sortie>J’AI</kbd-sortie> ;</li>
	<li><kbd>GT★</kbd> ➜ <kbd-sortie>J’ÉTAIS</kbd-sortie> ;</li>
	<li><kbd>M★</kbd> ➜ <kbd-sortie>MAIS</kbd-sortie> ;</li>
	<li><kbd>PCQ★</kbd> ➜ <kbd-sortie>PARCE QUE</kbd-sortie> ;</li>
	<li><kbd>PÊ★</kbd> ➜ <kbd-sortie>PEUT-ÊTRE</kbd-sortie> ;</li>
	<li><kbd>PEX★</kbd> ➜ <kbd-sortie>PAR EXEMPLE</kbd-sortie> ;</li>
	<li><kbd>R★</kbd> ➜ <kbd-sortie>RIEN</kbd-sortie> ;</li>
	<li>etc.</li>
</ul>
<p>
	Avec cette fonction d’abréviations, <NomPlus></NomPlus>
	<span class="important">devient plus qu’une disposition clavier</span>. Elle devient un outil de
	productivité permettant d’automatiser l’écriture des mots, voire phrases ou même textes les plus
	fréquents.
</p>
<p>
	C’est une fonctionnalité tout à fait optionnelle, libre à vous de ne pas utiliser les abréviations
	et de seulement utiliser la touche <kbd>★</kbd> afin de doubler la précédente lettre. Cependant, bien
	utilisée, cette touche peut être encore plus puissante.
</p>

<h3>
	Ajout des suffixes les plus communs en <kbd>À</kbd>
</h3>
<p>
	Il y a toujours un espace ou une ponctuation après un <kbd>À</kbd>, car les seuls mots l’utilisant
	sont
	<kbd-sortie>À</kbd-sortie>, <kbd-sortie>LÀ</kbd-sortie> et <kbd-sortie>DÉJÀ</kbd-sortie>. Par
	conséquent, toute combinaison de type <kbd>ÀS</kbd> ou
	<kbd>ÀC</kbd> n’est jamais tapée. Cela donne une opportunité extraordinaire de raccourcis pour augmenter
	sa vitesse et son confort de frappe.
</p>
<p>
	Par exemple, au lieu de taper 5 lettres pour écrire le suffixe
	<kbd-sortie>EMENT</kbd-sortie>, très souvent utilisé en français, deux frappes suffisent :
	<kbd>ÀS</kbd>. Ces raccourcis vont diviser par deux le nombre de touches nécessaires pour écrire
	les suffixes les plus communs,
	<span class="important">entraînant une augmentation de vitesse</span>.
</p>
<BlocClavier nom="a" />
