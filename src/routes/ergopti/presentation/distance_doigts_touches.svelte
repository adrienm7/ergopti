<script>
	import Ergopti from '#lib/components/Ergopti.svelte';
	import ErgoptiPlus from '#lib/components/ErgoptiPlus.svelte';
	import SFB from '#lib/components/SFB.svelte';

	import KeyboardBasis from '#lib/keyboard/KeyboardBasis.svelte';
	import { resolve } from '$app/paths';
</script>

<section>
	<h2 class="first-h2">Distance des doigts aux touches</h2>
	<h3>Optimisation de la rangée du milieu</h3>

	<p>
		Lors de l’apprentissage de la dactylographie, il est enseigné que les doigts doivent reposer sur
		la rangée du milieu (<kbd>QSDF</kbd>
		et <kbd>JKLM</kbd> en AZERTY). En particulier, il y a souvent une petite bosse sur les touches
		de repos pour les index, qui sont donc <kbd>F</kbd> et <kbd>J</kbd> en AZERTY.
	</p>
	<p>
		➜ L’idée est de taper sur une touche, puis de tout de suite replacer le doigt sur la rangée du
		milieu. Cela permet de toujours être capable de bouger rapidement dans n’importe quelle
		direction, un peu comme un sportif se replace toujours au milieu du terrain au cours d’un match.
	</p>
	<p>
		Nos doigts sont la plupart du temps sur la rangée du milieu : autant y placer les lettres les
		plus fréquentes. Les doigts n’ont alors presque plus besoin de bouger. Ils pressent les lettres
		de la rangée de repos et ne vont sur les autres rangées que pour les lettres les moins
		fréquentes.
	</p>
	<div class="keyboard-drawing" data-color="azerty">
		<div class="keyboard-row center">
			<div class="keyboard-key" data-finger="auriculaire" data-hand="left" style="--size: 1;">
				<div>Q</div>
			</div>
			<div class="keyboard-key" data-finger="annulaire" data-hand="left" style="--size: 1;">
				<div>S</div>
			</div>
			<div class="keyboard-key" data-finger="majeur" data-hand="left" style="--size: 1;">
				<div>D</div>
			</div>
			<div class="keyboard-key" data-finger="index" data-hand="left" style="--size: 1;">
				<div>F</div>
			</div>

			<div style="display: inline-block; width: 50px;"></div>

			<div class="keyboard-key" data-finger="index" data-hand="right" style="--size: 1;">
				<div>J</div>
			</div>
			<div class="keyboard-key" data-finger="majeur" data-hand="right" style="--size: 1;">
				<div>K</div>
			</div>
			<div class="keyboard-key" data-finger="annulaire" data-hand="right" style="--size: 1;">
				<div>L</div>
			</div>
			<div class="keyboard-key" data-finger="auriculaire" data-hand="right" style="--size: 1;">
				<div>M</div>
			</div>
		</div>
		<p class="keyboard-legend">Rangée du milieu en AZERTY</p>
	</div>

	<p>
		Pourtant, le QWERTY (et donc l’AZERTY) ne fait pas mieux qu’une disposition aléatoire sur ce
		point. Son origine fait l’objet de multiples théories. L’une des plus connues avance qu’elle
		aurait été conçue pour réduire les risques d’enchevêtrement des marteaux sur les premières
		machines à écrire. Cependant, cette explication est remise en question par de nombreuses
		personnes. D’autres motivations, notamment d’ordre commercial, ont également pu influencer ce
		choix. À titre d’exemple, la rangée supérieure des touches aurait été organisée de façon à
		permettre d’écrire aisément le mot <samp class="kbd-output" lang="en">TYPEWRITER</samp> lors de démonstrations
		publiques, renforçant ainsi l’attrait des machines.
	</p>
	<p>
		Certaines des lettres les plus rares (en français et en anglais) occupent ces excellents
		emplacements, comme le <kbd>Q</kbd>, le <kbd>F</kbd>, le <kbd>J</kbd> et le <kbd>K</kbd>. Pire,
		presque toutes les lettres les plus utilisées sont sur la rangée du dessus (<kbd>AZERTYUIOP</kbd
		>). C’est le cas de toutes les voyelles (sauf du <kbd>A</kbd> en QWERTY) : elles sont peu nombreuses
		face aux consonnes, mais chaque mot en contient.
	</p>

	<div class="keyboard-drawing" data-color="ergopti">
		<div class="keyboard-row center">
			<div class="keyboard-key" data-finger="auriculaire" data-hand="left" style="--size: 1;">
				<div>A</div>
			</div>
			<div class="keyboard-key" data-finger="annulaire" data-hand="left" style="--size: 1;">
				<div>I</div>
			</div>
			<div class="keyboard-key" data-finger="majeur" data-hand="left" style="--size: 1;">
				<div>E</div>
			</div>
			<div class="keyboard-key" data-finger="index" data-hand="left" style="--size: 1;">
				<div>U</div>
			</div>

			<div style="display: inline-block; width: 50px;"></div>

			<div class="keyboard-key" data-finger="index" data-hand="right" style="--size: 1;">
				<div>S</div>
			</div>
			<div class="keyboard-key" data-finger="majeur" data-hand="right" style="--size: 1;">
				<div>N</div>
			</div>
			<div class="keyboard-key" data-finger="annulaire" data-hand="right" style="--size: 1;">
				<div>T</div>
			</div>
			<div class="keyboard-key" data-finger="auriculaire" data-hand="right" style="--size: 1;">
				<div>R</div>
			</div>
		</div>
		<p class="keyboard-legend">Rangée du milieu en <Ergopti></Ergopti></p>
	</div>
	<p>
		En français et en anglais, le <kbd>E</kbd> est de très loin la lettre la plus fréquente.
		Viennent ensuite les voyelles <kbd>A</kbd>, <kbd>I</kbd>, <kbd>O</kbd> et <kbd>U</kbd>, ainsi
		que les consonnes <kbd>S</kbd>, <kbd>N</kbd>, <kbd>T</kbd> et <kbd>R</kbd>. <Ergopti /> place donc
		les lettres les plus utilisées sur la rangée du milieu. En résulte immédiatement un déplacement des
		doigts largement diminué et un meilleur confort.
	</p>

	<h3>Optimisation selon la force des doigts</h3>
	<p>
		Une fois que les lettres les plus fréquentes ont été placées sur la rangée du milieu, il reste
		encore beaucoup à faire. En effet, <strong>chaque doigt a une force différente</strong>. Ainsi,
		un pouce a plus de force qu’un index, qui a plus de force qu’un majeur. Le majeur a plus de
		force qu’un annulaire, qui a plus de force qu’un auriculaire. Il est facile de s’en rendre
		compte : presser fort de l’index sur une table, puis tenter de faire de même avec son
		auriculaire met en lumière cette différence.
	</p>
	<p>
		Par conséquent, les meilleurs emplacements sont ceux sur la rangée de repos, en partant de
		l’index pour aller vers l’annulaire. Puis, les meilleurs emplacements seront sur les touches
		au-dessus et en-dessous de la rangée de repos, en partant là encore de l’index pour aller vers
		l’annulaire.
	</p>
	<!-- <p style="text-align:center; color:red;">
			[METTRE ICI UN CLAVIER VIDE MONTRANT LES MEILLEURS EMPLACEMENTS EN COULEUR]
		</p> -->

	<p class="space-before-tiny">
		La rangée des chiffres est donc encore moins accessible, car il faut traverser deux rangées
		depuis la rangée de repos pour l’atteindre. Laisser le <kbd>É</kbd> sur cette ligne comme en
		AZERTY est donc une très mauvaise idée, car cette lettre est beaucoup utilisée en français. Il y
		est environ 2 fois plus fréquent que le <kbd>J</kbd>. Pourtant, en AZERTY, c’est le <kbd>J</kbd>
		qui occupe l’un des meilleurs emplacements du clavier : la touche de repos de l’index.
	</p>
	<p class="space-after-tiny">
		Enfin, contrairement à BÉPO ou Optimot, <Ergopti /> ne place pas de symboles de programmation ou
		de ponctuation sur la rangée des chiffres. Ces symboles sont ramenés au plus près des doigts grâce
		à l’utilisation de la couche <kbd>AltGr</kbd>.
	</p>

	<KeyboardBasis id="frequences" />

	<p class="space-before-tiny">
		Comme le montre le clavier ci-dessus, les lettres les plus fréquentes sont bien sur la rangée du
		milieu en <Ergopti />. Effectivement, la lettre la plus fréquente, le <kbd>E</kbd>, est en
		rouge. Viennent ensuite en orange les voyelles et consonnes les plus fréquentes. Enfin, les
		lettres en vert, voire bleu, sont les moins fréquentes de toutes.
	</p>
	<p>
		Attention toutefois, car ces fréquences vont varier selon le texte analysé et la langue de
		celui-ci. Vous trouverez plus de détails sur la page <a
			href={resolve('/ergopti/benchmarks')}
			class="link">Benchmarks</a
		>.
	</p>
</section>
