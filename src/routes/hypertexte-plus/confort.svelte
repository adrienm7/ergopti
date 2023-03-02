<script>
	import Nom from '$lib/composants/Nom.svelte';
	import Nom_Plus from '$lib/composants/Nom_Plus.svelte';
	import SFB from '$lib/composants/SFB.svelte';
</script>

<h3>[QU] automatiques avant les voyelles</h3>
<p>
	La touche <kbd>Q</kbd> est à 99% suivie de <kbd>U</kbd> si une voyelle vient ensuite. Par
	conséquent, lors de la frappe de <kbd>Q</kbd> + <kbd>Voyelle</kbd>, un <kbd>U</kbd> s’intercale
	automatiquement entre les deux pour donner <kbd-sortie>Q</kbd-sortie> + <kbd-sortie>U</kbd-sortie>
	+ <kbd-sortie>Voyelle</kbd-sortie>.
</p>

<h3>[OÙ]</h3>
<p>
	La touche <kbd>Ù</kbd> n’est utilisée que pour écrire <kbd>OÙ</kbd>. Ainsi, autant tranformer
	cette touche en raccourci pour écrire <kbd-sortie>OÙ</kbd-sortie> pour économiser une frappe
	certaine sur la touche <kbd>O</kbd> et améliorer l’alternance des mains.
</p>

<h3>Utilisation de la touche <kbd>À</kbd> : en tant que J</h3>
<p>
	La touche <kbd>J</kbd> est très loin et pourtant relativement souvent utilisée en français, en
	particulier pour écrire <kbd>JE</kbd>. Les combinaisons <kbd-non>ÀI</kbd-non>,
	<kbd-non>ÀE</kbd-non>, etc. n’existent pas en français. En fait, la lettre <kbd>À</kbd> est
	toujours suivie d’un espace ou d’un caractère de ponctuation. Cela donne une formidable
	opportunité d’utiliser cette touche comme un <kbd-sortie>J</kbd-sortie>, si elle est suivie d’une
	voyelle.
</p>
<p>
	Dans les rares cas où vous voudrez écrire <kbd>J</kbd> + <kbd>Consonne</kbd>, il faudra utiliser
	la vraie touche <kbd-sortie>J</kbd-sortie>. De même si vous voulez utiliser un raccourci avec
	<kbd>J</kbd> comme <kbd>Ctrl</kbd> + <kbd>J</kbd> pour justifier un texte.
</p>
<ul class="margin-top-2">
	<li><kbd>ÀY</kbd> ➜ <kbd-sortie>AJ</kbd-sortie></li>
	<li><kbd>ÀW</kbd> ➜ <kbd-sortie>JA</kbd-sortie> (pour éviter un <SFB />)</li>
	<li><kbd>ÀI</kbd> ➜ <kbd-sortie>JI</kbd-sortie></li>
	<li><kbd>ÀE</kbd> ➜ <kbd-sortie>JE</kbd-sortie></li>
	<li><kbd>ÀÉ</kbd> ➜ <kbd-sortie>JÉ</kbd-sortie></li>
	<li><kbd>ÀO</kbd> ➜ <kbd-sortie>JO</kbd-sortie></li>
	<li><kbd>ÀU</kbd> ➜ <kbd-sortie>ÀU</kbd-sortie></li>
</ul>

<h3><kbd>Ê</kbd> fait office de <kbd>^</kbd></h3>
<p>
	La touche morte <kbd>^</kbd> est très loin sur un clavier standard. La majorité du temps, elle est
	utilisée pour écrire <kbd>Ê</kbd>, qui est une touche déjà présente sur l’annulaire gauche.
	Toutefois, dans de rares cas, il est nécessaire d’écrire <kbd>Â</kbd>, <kbd>Î</kbd>, <kbd>Ô</kbd>
	ou encore
	<kbd>Û</kbd>. C’est pour cela que <kbd>ÊA</kbd> donne
	<kbd-sortie>Â</kbd-sortie> par exemple.
</p>
<p>
	À noter que pour écrire <kbd-sortie>Î</kbd-sortie>, plutôt que de faire un <SFB /> en tapant
	<kbd>ÊI</kbd>, vous pouvez aussi faire <kbd>ÊE</kbd>.
</p>

<h3>Remplacement automatique des <kbd>'</kbd> par <kbd>’</kbd> pour le français</h3>
<p>
	Quand on écrit en français, il faudrait utiliser l’apostrophe typographique plutôt que
	l’apostrophe droite.
</p>
<p>
	Un autre raccourci a été ajouté pour avoir la possibilité d’écrire <kbd-sortie>N'T</kbd-sortie>
	par un roulement. Effectivement, <kbd>NT’</kbd> se transforme en <kbd-sortie>N'T</kbd-sortie> pour
	pouvoir faire [majeur, annulaire, auriculaire] plutôt que [majeur, auriculaire, annulaire].
</p>
