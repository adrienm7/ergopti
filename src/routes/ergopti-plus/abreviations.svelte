<script>
	import Ergopti from '$lib/components/Ergopti.svelte';
	import ErgoptiPlus from '$lib/components/ErgoptiPlus.svelte';
	import SFB from '$lib/components/SFB.svelte';

	import KeyboardBasis from '$lib/keyboard/KeyboardBasis.svelte';
</script>

<h2>Abréviations</h2>
<h3>Remplacement de texte avec <kbd>★</kbd></h3>
<p>
	Le comportement par défaut de la touche <kbd>★</kbd> est de répéter dernière touche tapée.
	Cependant, dans le cas où une abréviation terminant par cette touche existe dans la liste
	d’abréviations, alors celle-ci sera renvoyée à la place. Ainsi,
	<kbd>r★</kbd> envoie le raccourci <kbd-sortie>rien</kbd-sortie>, tandis que <kbd>ar★iver</kbd>
	enverra <kbd-sortie>arriver</kbd-sortie>. De même, <kbd>av★</kbd> enverra
	<kbd-sortie>avv</kbd-sortie> et <kbd>avv★</kbd> enverra <kbd-sortie>avez-vous</kbd-sortie>.
</p>
<tiny-space></tiny-space>
<p class="text-bold">Liste de quelques-unes des abréviations (liste modifiable par vos soins) :</p>
<ul>
	<li><kbd>a★</kbd> ➜ <kbd-sortie>ainsi</kbd-sortie> ;</li>
	<li><kbd>avv★</kbd> ➜ <kbd-sortie>avez-vous</kbd-sortie> ;</li>
	<li><kbd>c★</kbd> ➜ <kbd-sortie>c’est</kbd-sortie> ;</li>
	<li><kbd>ct★</kbd> ➜ <kbd-sortie>c’était</kbd-sortie> ;</li>
	<li><kbd>dé★</kbd> ➜ <kbd-sortie>déjà</kbd-sortie> ;</li>
	<li><kbd>ê★</kbd> ➜ <kbd-sortie>être</kbd-sortie> ;</li>
	<li><kbd>eef★</kbd> ➜ <kbd-sortie>en effet</kbd-sortie> ;</li>
	<li><kbd>f★</kbd> ➜ <kbd-sortie>faire</kbd-sortie> ;</li>
	<li><kbd>g★</kbd> ➜ <kbd-sortie>j’ai</kbd-sortie> ;</li>
	<li><kbd>gt★</kbd> ➜ <kbd-sortie>j’étais</kbd-sortie> ;</li>
	<li><kbd>m★</kbd> ➜ <kbd-sortie>mais</kbd-sortie> ;</li>
	<li><kbd>pcq★</kbd> ➜ <kbd-sortie>parce que</kbd-sortie> ;</li>
	<li><kbd>pê★</kbd> ➜ <kbd-sortie>peut-être</kbd-sortie> ;</li>
	<li><kbd>pex★</kbd> ➜ <kbd-sortie>par exemple</kbd-sortie> ;</li>
	<li><kbd>r★</kbd> ➜ <kbd-sortie>rien</kbd-sortie> ;</li>
	<li>etc.</li>
</ul>
<p>
	Avec cette fonction d’abréviations, <ErgoptiPlus></ErgoptiPlus>
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
	Il y a toujours un espace ou une ponctuation après un <kbd>à</kbd>, car les seuls mots l’utilisant
	sont <kbd-sortie>à</kbd-sortie>, <kbd-sortie>là</kbd-sortie> et <kbd-sortie>déjà</kbd-sortie>. Par
	conséquent, toute combinaison de type <kbd>às</kbd> ou <kbd>àc</kbd> n’est jamais tapée. Cela donne
	une opportunité extraordinaire de raccourcis pour augmenter sa vitesse et son confort de frappe.
</p>
<p>
	Par exemple, au lieu de taper 5 lettres pour écrire le suffixe
	<kbd-sortie>ement</kbd-sortie>, très souvent utilisé en français, deux frappes suffisent :
	<kbd>às</kbd>. Ces raccourcis vont diviser par deux le nombre de touches nécessaires pour écrire
	les suffixes les plus communs,
	<span class="important">entraînant une augmentation de vitesse</span>.
</p>
<KeyboardBasis name="a" />
