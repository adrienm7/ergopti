<script>
	import Nom from '$lib/composants/Nom.svelte';
	import NomPlus from '$lib/composants/NomPlus.svelte';
	import SFB from '$lib/composants/SFB.svelte';
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
	<li><kbd>D★</kbd> ➜ <kbd-sortie>DONC</kbd-sortie> ;</li>
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
	Il y a toujours un espace ou une ponctuation après un <kbd>À</kbd>, car les deux seuls mots
	l’utilisant sont
	<kbd-sortie>À</kbd-sortie>
	et <kbd-sortie>DÉJÀ</kbd-sortie>. Par conséquent, toute combinaison de type <kbd>ÀS</kbd> ou
	<kbd>ÀC</kbd> n’est jamais tapée. Cela donne une opportunité extraordinaire de raccourcis pour
	augmenter sa vitesse et son confort de frappe. Par exemple, au lieu de taper 5 lettres pour écrire
	le suffixe
	<kbd-sortie>EMENT</kbd-sortie>, très souvent utilisé en français, deux frappes suffisent :
	<kbd>ÀS</kbd>. Ces raccourcis vont diviser par deux le nombre de touches nécessaires pour écrire
	les suffixes les plus communs,
	<span class="important">entraînant une augmentation de vitesse</span>.
</p>
<p>
	Le confort est aussi visé, par exemple pour la combinaison <kbd-sortie>GHT</kbd-sortie> qui est un
	peu inconfortable à faire en <Nom />, car il faut frapper de l’annulaire droit, du majeur droit,
	puis encore de l’annulaire droit. Ce n’est pas un beau roulement, alors qu’au contraire
	<kbd>ÀG</kbd>
	écrira <kbd-sortie>IGHT</kbd-sortie> et <kbd>ÀP</kbd> écrira <kbd-sortie>OUGH</kbd-sortie>.
</p>
<mini-espace />
<p class="text-bold">Liste des suffixes implémentés :</p>
<ul>
	<li><kbd>ÀA</kbd> ➜ <kbd-sortie>AIRE</kbd-sortie> ;</li>
	<li><kbd>ÀB</kbd> ➜ Rien, car peu confortable ;</li>
	<li><kbd>ÀC</kbd> ➜ <kbd-sortie>ENCE</kbd-sortie> ;</li>
	<li><kbd>ÀD</kbd> ➜ <kbd-sortie>OULD</kbd-sortie> ;</li>
	<li><kbd>ÀE</kbd> ➜ Rien, pour éviter un <SFB /> ;</li>
	<li><kbd>ÀÉ</kbd> ➜ <kbd-sortie>YING</kbd-sortie> ;</li>
	<li><kbd>ÀÈ</kbd> ➜ Rien, car peu confortable ;</li>
	<li><kbd>ÀÊ</kbd> ➜ <kbd-sortie>ABLE</kbd-sortie> ;</li>
	<li><kbd>ÀF</kbd> ➜ <kbd-sortie>ISTE</kbd-sortie> ;</li>
	<li><kbd>ÀG</kbd> ➜ <kbd-sortie>IGHT</kbd-sortie> ;</li>
	<li><kbd>ÀH</kbd> ➜ <kbd-sortie>TECHN</kbd-sortie> ;</li>
	<li><kbd>ÀI</kbd> ➜ <kbd-sortie>IGHT</kbd-sortie> ;</li>
	<li><kbd>ÀJ</kbd> ➜ Rien, car peu confortable ;</li>
	<li><kbd>ÀK</kbd> ➜ <kbd-sortie>IQUE</kbd-sortie> ;</li>
	<li><kbd>ÀL</kbd> ➜ <kbd-sortie>ELLE</kbd-sortie> ;</li>
	<li><kbd>ÀM</kbd> ➜ <kbd-sortie>ISME</kbd-sortie> ;</li>
	<li><kbd>ÀN</kbd> ➜ <kbd-sortie>ATION</kbd-sortie> ;</li>
	<li><kbd>ÀO</kbd> ➜ Rien, pour éviter un <SFB /> ;</li>
	<li><kbd>ÀP</kbd> ➜ <kbd-sortie>OUGHT</kbd-sortie> ;</li>
	<li><kbd>ÀQ</kbd> ➜ <kbd-sortie>IQUE</kbd-sortie> ;</li>
	<li><kbd>ÀR</kbd> ➜ <kbd-sortie>ERRE</kbd-sortie> ;</li>
	<li><kbd>ÀS</kbd> ➜ <kbd-sortie>EMENT</kbd-sortie> ;</li>
	<li><kbd>ÀT</kbd> ➜ <kbd-sortie>CTION</kbd-sortie> ;</li>
	<li><kbd>ÀU</kbd> ➜ <kbd-sortie>UB</kbd-sortie> ;</li>
	<li><kbd>ÀV</kbd> ➜ <kbd-sortie>ANCE</kbd-sortie> ;</li>
	<li><kbd>ÀW</kbd> ➜ Rien, car peu confortable</li>
	<li><kbd>ÀX</kbd> ➜ <kbd-sortie>IEUX</kbd-sortie> ;</li>
	<li><kbd>ÀY</kbd> ➜ Rien, car peu confortable ;</li>
	<li><kbd>ÀZ</kbd> ➜ <kbd-sortie>EZ-VOUS</kbd-sortie> ;</li>
	<li><kbd>À★</kbd> ➜ <kbd-sortie>BU</kbd-sortie> ;</li>
	<li><kbd>À’</kbd> ➜ Rien pour le moment.</li>
</ul>
