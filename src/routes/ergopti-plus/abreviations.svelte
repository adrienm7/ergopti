<script>
	import Ergopti from '$lib/components/Ergopti.svelte';
	import ErgoptiPlus from '$lib/components/ErgoptiPlus.svelte';
	import SFB from '$lib/components/SFB.svelte';

	import KeyboardBasis from '$lib/keyboard/KeyboardBasis.svelte';
</script>

<section>
	<h2>Abréviations</h2>
	<h3>Remplacement de texte avec <kbd class="glow">★</kbd></h3>
	<p>
		Le comportement par défaut de la touche <kbd class="glow">★</kbd> est de répéter dernière touche
		tapée. Cependant, dans le cas où une abréviation terminant par cette touche existe dans la liste
		d’abréviations, alors celle-ci sera renvoyée à la place. Ainsi,
		<kbd>r★</kbd> envoie le raccourci <kbd-output>rien</kbd-output>, tandis que <kbd>ar★iver</kbd>
		enverra <kbd-output>arriver</kbd-output>. De même, <kbd>av★</kbd> enverra
		<kbd-output>avv</kbd-output> et <kbd>avv★</kbd> enverra <kbd-output>avez-vous</kbd-output>.
	</p>
	<tiny-space></tiny-space>
	<p class="text-bold">
		Liste de quelques-unes des abréviations (liste modifiable par vos soins) :
	</p>
	<ul>
		<li><kbd>a★</kbd> ➜ <kbd-output>ainsi</kbd-output> ;</li>
		<li><kbd>avv★</kbd> ➜ <kbd-output>avez-vous</kbd-output> ;</li>
		<li><kbd>c★</kbd> ➜ <kbd-output>c’est</kbd-output> ;</li>
		<li><kbd>ct★</kbd> ➜ <kbd-output>c’était</kbd-output> ;</li>
		<li><kbd>dé★</kbd> ➜ <kbd-output>déjà</kbd-output> ;</li>
		<li><kbd>ê★</kbd> ➜ <kbd-output>être</kbd-output> ;</li>
		<li><kbd>eef★</kbd> ➜ <kbd-output>en effet</kbd-output> ;</li>
		<li><kbd>f★</kbd> ➜ <kbd-output>faire</kbd-output> ;</li>
		<li><kbd>g★</kbd> ➜ <kbd-output>j’ai</kbd-output> ;</li>
		<li><kbd>gt★</kbd> ➜ <kbd-output>j’étais</kbd-output> ;</li>
		<li><kbd>m★</kbd> ➜ <kbd-output>mais</kbd-output> ;</li>
		<li><kbd>pcq★</kbd> ➜ <kbd-output>parce que</kbd-output> ;</li>
		<li><kbd>pê★</kbd> ➜ <kbd-output>peut-être</kbd-output> ;</li>
		<li><kbd>pex★</kbd> ➜ <kbd-output>par exemple</kbd-output> ;</li>
		<li><kbd>r★</kbd> ➜ <kbd-output>rien</kbd-output> ;</li>
		<li>etc.</li>
	</ul>
	<p>
		Avec cette fonction d’abréviations, <ErgoptiPlus></ErgoptiPlus>
		<strong>devient plus qu’une disposition clavier</strong>. Elle se transforme en un outil de
		productivité permettant d’automatiser l’écriture des mots, voire phrases ou même textes les plus
		fréquents.
	</p>
	<p>
		C’est une fonctionnalité tout à fait optionnelle, libre à vous de ne pas utiliser les
		abréviations et de seulement utiliser la touche <kbd class="glow">★</kbd> afin de doubler la précédente
		lettre. Cependant, bien utilisée, cette touche peut être encore plus puissante.
	</p>

	<h3>
		Ajout des suffixes les plus communs en <kbd>À</kbd>
	</h3>
	<p>
		Il y a toujours un espace ou une ponctuation après un <kbd>à</kbd>, car les seuls mots
		l’utilisant sont <kbd-output>à</kbd-output>, <kbd-output>là</kbd-output> et
		<kbd-output>déjà</kbd-output>. Par conséquent, toute combinaison de type <kbd>às</kbd> ou
		<kbd>àc</kbd> n’est jamais tapée. Cela donne une opportunité extraordinaire de raccourcis pour augmenter
		sa vitesse et son confort de frappe.
	</p>
	<p>
		Par exemple, au lieu de taper 5 lettres pour écrire le suffixe
		<kbd-output>ement</kbd-output>, très souvent utilisé en français, deux frappes suffisent :
		<kbd>às</kbd>. Ces raccourcis vont diviser par deux le nombre de touches nécessaires pour écrire
		les suffixes les plus communs,
		<strong>entraînant une augmentation de vitesse</strong>.
	</p>
	<KeyboardBasis id="a" />
</section>
