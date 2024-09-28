<script>
	import Nom from '$lib/composants/Nom.svelte';
	import NomPlus from '$lib/composants/NomPlus.svelte';
	import SFB from '$lib/composants/SFB.svelte';
</script>

<section>
	<h3 data-aos="fade-right" data-aos-mirror="true">[QU] automatiques avant les voyelles</h3>
	<div class="content">
		<p>
			La touche <kbd>Q</kbd> est à 99% suivie de <kbd>U</kbd> si une voyelle vient ensuite. Par
			conséquent, lors de la frappe de <kbd>Q</kbd> + <kbd>Voyelle</kbd>, un <kbd>U</kbd>
			s’intercale automatiquement entre les deux pour donner <kbd-sortie>Q</kbd-sortie> +
			<kbd-sortie>U</kbd-sortie>
			+ <kbd-sortie>Voyelle</kbd-sortie>.
		</p>
	</div>

	<h3 data-aos="fade-right" data-aos-mirror="true">[OÙ]</h3>
	<div class="content">
		<p>
			La touche <kbd>Ù</kbd> n’est utilisée que pour écrire <kbd>OÙ</kbd>. Ainsi, autant tranformer
			cette touche en raccourci pour écrire <kbd-sortie>OÙ</kbd-sortie> pour économiser une frappe
			certaine sur la touche <kbd>O</kbd> et améliorer l’alternance des mains.
		</p>
	</div>

	<h3 data-aos="fade-right" data-aos-mirror="true">
		<kbd>Ê</kbd> fait office de <kbd>^</kbd>
	</h3>

	<div class="content">
		<p>
			La touche morte <kbd>^</kbd> est utilisée la majorité du temps pour écrire <kbd>Ê</kbd>. C’est
			pour cela qu’une touche <kbd>Ê</kbd> a été placée sur l’annulaire gauche afin d’éviter un
			appui sur deux touches pour cette lettre circonflexe très commune. Toutefois, dans de rares
			cas, il est nécessaire d’écrire <kbd>Â</kbd>, <kbd>Î</kbd>,
			<kbd>Ô</kbd>
			ou encore
			<kbd>Û</kbd>. C’est pour cela que <kbd>ÊA</kbd> va donner
			<kbd-sortie>Â</kbd-sortie>, <kbd>ÊI</kbd> va donner <kbd-sortie>Î</kbd-sortie>, etc. Cela
			permet de ne plus du tout avoir à utiliser la touche morte <kbd>^</kbd>, et donc bouger encore
			moins les mains.
		</p>
		<p>
			Le seul problème est que la combinaison <kbd>AÎ</kbd> (par exemple pour écrire "paraît") se
			transforme en <SFB />. Heureusement, le mécanisme de correction automatique de <NomPlus /> permet
			de corriger cela et de donner
			<kbd-sortie>paraît</kbd-sortie>
			lors de l’écriture de <kbd>parait</kbd>, rendant ce <SFB /> inoffensif.
		</p>
		<p>
			À noter que pour écrire <kbd-sortie>Â</kbd-sortie> et éviter un <SFB />, il est aussi possible
			de faire <kbd>ÊÀ</kbd>.
		</p>
	</div>

	<h3 data-aos="fade-right" data-aos-mirror="true">
		Remplacement automatique des <kbd>'</kbd> par <kbd>’</kbd> pour le français
	</h3>

	<div class="content">
		<p>
			Lorsque l’on écrit en français, il faudrait idéalement utiliser l’apostrophe typographique
			plutôt que l’apostrophe droite. C’est pour cela que <NomPlus /> va automatiquement l’utiliser à
			la place de l’apostrophe droite lors de l’écriture en français.
		</p>
		<!-- <p>
			Un autre raccourci a été ajouté pour avoir la possibilité d’écrire <kbd-sortie>N'T</kbd-sortie
			>
			par un roulement. Effectivement, <kbd>NT’</kbd> se transforme en
			<kbd-sortie>N'T</kbd-sortie> pour pouvoir faire [majeur, annulaire, auriculaire] plutôt que [majeur,
			auriculaire, annulaire].
		</p> -->
	</div>

	<h3 data-aos="fade-right" data-aos-mirror="true">
		Utilisation de la touche <kbd>,</kbd> : en tant que J
	</h3>

	<div class="content">
		<p>
			La touche <kbd>J</kbd> est très loin et pourtant relativement souvent utilisée en français, en
			particulier pour écrire <kbd>JE</kbd>. Les combinaisons <kbd-non>,I</kbd-non>,
			<kbd-non>,E</kbd-non>, etc. n’existent pas en français. En réalité, la lettre <kbd>,</kbd> est
			systématiquement suivie d’un espace ou d’un caractère de ponctuation. Cela donne une
			formidable opportunité d’utiliser cette touche comme un <kbd-sortie>J</kbd-sortie>, si elle
			est suivie d’une voyelle.
		</p>
		<p>
			Dans les rares cas où vous voudrez écrire <kbd>J</kbd> + <kbd>Consonne</kbd>, il faudra
			utiliser la vraie touche <kbd-sortie>J</kbd-sortie>. De même si vous voulez utiliser un
			raccourci avec
			<kbd>J</kbd> comme <kbd>Ctrl</kbd> + <kbd>J</kbd> pour justifier un texte.
		</p>
		<ul class="margin-top-2">
			<li><kbd>,A</kbd> ➜ <kbd-sortie>JA</kbd-sortie></li>
			<li><kbd>,I</kbd> ➜ <kbd-sortie>JI</kbd-sortie></li>
			<li><kbd>,E</kbd> ➜ <kbd-sortie>JE</kbd-sortie></li>
			<li><kbd>,É</kbd> ➜ <kbd-sortie>JÉ</kbd-sortie></li>
			<li><kbd>,O</kbd> ➜ <kbd-sortie>JO</kbd-sortie></li>
			<li><kbd>,Ê</kbd> ➜ <kbd-sortie>JU</kbd-sortie></li>
		</ul>
	</div>
</section>
