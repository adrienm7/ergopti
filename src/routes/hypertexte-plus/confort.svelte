<script>
	import Nom from '../../composants/Nom.svelte';
	import Nom_Plus from '../../composants/Nom_Plus.svelte';
	import SFB from '../../composants/SFB.svelte';
</script>

<h2>Ajouts de confort</h2>
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
	La touche <kbd>J</kbd> est très loin et pourtant relativement souvent utilisée en français,
	notammentt pour écrire <em>je</em>. Les combinaisons <em>ÀI</em>, <em>ÀE</em>, etc. n’existent pas
	en français. En fait, <kbd>À</kbd> est toujours suivie d’un espace. Cela donne une formidable opportunité
	d’utiliser cette touche À comme J, si elle est suivie d’une voyelle.
</p>
<h3><kbd>Ê</kbd> fait office de <kbd>^</kbd></h3>
<p>
	La touche morte <kbd>^</kbd> est très loin sur un clavier standard. La majorité des fois elle est
	utilisée pour écrire ê, qui est une touche présente sur l’annulaire gauche. Toutefois, dans de
	rares cas il est nécessaire de taper â, î, ô ou encore û. C’est pour cela que <kbd>ÊA</kbd> donne
	<kbd-sortie>Â</kbd-sortie>
	par exemple.
</p>
<p>
	À noter que pour écrire Î, plutôt que de faire un <SFB /> en tapant <kbd>ÊI</kbd>, vous pouvez
	aussi faire <kbd>ÊE</kbd>.
</p>
<h3>Remplacement automatique des <kbd>’</kbd> par <kbd>'</kbd> pour l’anglais</h3>
<p>
	En anglais, l’apostrophe typographique n’est pas utilisée. Afin d’écrire "correctement" en anglais
	sans perte de vitesse ni besoin de réflexion pour savoir quelle apostrophe taper, des
	remplacements de texte ont été introduits. Ainsi, <kbd>t’s</kbd> et <kbd>n’t</kbd> sont
	automatiquement remplacés par les bonnes apostrophes : <kbd-sortie>t's</kbd-sortie> et
	<kbd-sortie>n't</kbd-sortie>.
</p>
<p>
	Un autre raccourci a été ajouté pour avoir la possibilité d’écrire <kbd-sortie>n't</kbd-sortie>
	par un roulement. Effectivement, <kbd>nt’</kbd> se transforme en <kbd-sortie>n't</kbd-sortie> pour
	pouvoir faire [majeur, annulaire, auriculaire] plutôt que [majeur, auriculaire, annulaire].
</p>
