<script>
	import Ergopti from '$lib/components/Ergopti.svelte';
	import ErgoptiPlus from '$lib/components/ErgoptiPlus.svelte';
	import SFB from '$lib/components/SFB.svelte';

	import KeyboardBasis from '$lib/keyboard/KeyboardBasis.svelte';
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
		Il est alors logique de se dire que nos doigts étant la plupart du temps sur la rangée du
		milieu, autant y placer les lettres les plus fréquemment utilisées. En procédant ainsi, il n’y a
		presque plus besoin de bouger les doigts, juste à presser les lettres de la rangée de repos et
		parfois atteindre les rangées supérieures ou inférieures pour les lettres les moins fréquentes.
	</p>
	<keyboard data-color="azerty">
		<keyboard-row class="center">
			<keyboard-key data-finger="auriculaire" data-hand="left" style="--size: 1;">
				<div>Q</div>
			</keyboard-key>
			<keyboard-key data-finger="annulaire" data-hand="left" style="--size: 1;">
				<div>S</div>
			</keyboard-key>
			<keyboard-key data-finger="majeur" data-hand="left" style="--size: 1;">
				<div>D</div>
			</keyboard-key>
			<keyboard-key data-finger="index" data-hand="left" style="--size: 1;">
				<div>F</div>
			</keyboard-key>

			<div style="display: inline-block; width: 50px;"></div>

			<keyboard-key data-finger="index" data-hand="right" style="--size: 1;">
				<div>J</div>
			</keyboard-key>
			<keyboard-key data-finger="majeur" data-hand="right" style="--size: 1;">
				<div>K</div>
			</keyboard-key>
			<keyboard-key data-finger="annulaire" data-hand="right" style="--size: 1;">
				<div>L</div>
			</keyboard-key>
			<keyboard-key data-finger="auriculaire" data-hand="right" style="--size: 1;">
				<div>M</div>
			</keyboard-key>
		</keyboard-row>
		<keyboard-legend>Rangée du milieu en AZERTY</keyboard-legend>
	</keyboard>

	<p>
		Pourtant, le QWERTY (et donc l’AZERTY) ne fait pas mieux qu’une disposition aléatoire sur ce
		point. Son origine fait l’objet de multiples théories. L’une des plus connues avance qu’elle
		aurait été conçue pour réduire les risques d’enchevêtrement des marteaux sur les premières
		machines à écrire. Cependant, cette explication est remise en question par de nombreuses
		personnes. D’autres motivations, notamment d’ordre commercial, ont également pu influencer ce
		choix. À titre d’exemple, la rangée supérieure des touches aurait été organisée de façon à
		permettre d’écrire aisément le mot <kbd-output>TYPEWRITER</kbd-output> lors de démonstrations publiques,
		renforçant ainsi l’attrait des machines.
	</p>
	<p>
		Certaines des touches ayant les fréquences d’apparition les plus rares (en français et en
		anglais) sont sur ces excellents emplacements comme le <kbd>Q</kbd>, le <kbd>F</kbd>, le
		<kbd>J</kbd> et le <kbd>K</kbd>. Pire, la quasi-totalité des touches les plus utilisées se
		retrouvent en fait sur la rangée du dessus (<kbd>AZERTYUIOP</kbd>). C’est notamment le cas de
		toutes les voyelles (sauf du <kbd>A</kbd> en QWERTY), dont le nombre est faible comparé au nombre
		de consonnes, mais qui sont toutefois incontournables pour l’écriture de chaque mot.
	</p>

	<keyboard data-color="ergopti">
		<keyboard-row class="center">
			<keyboard-key data-finger="auriculaire" data-hand="left" style="--size: 1;">
				<div>A</div>
			</keyboard-key>
			<keyboard-key data-finger="annulaire" data-hand="left" style="--size: 1;">
				<div>I</div>
			</keyboard-key>
			<keyboard-key data-finger="majeur" data-hand="left" style="--size: 1;">
				<div>E</div>
			</keyboard-key>
			<keyboard-key data-finger="index" data-hand="left" style="--size: 1;">
				<div>U</div>
			</keyboard-key>

			<div style="display: inline-block; width: 50px;"></div>

			<keyboard-key data-finger="index" data-hand="right" style="--size: 1;">
				<div>S</div>
			</keyboard-key>
			<keyboard-key data-finger="majeur" data-hand="right" style="--size: 1;">
				<div>N</div>
			</keyboard-key>
			<keyboard-key data-finger="annulaire" data-hand="right" style="--size: 1;">
				<div>T</div>
			</keyboard-key>
			<keyboard-key data-finger="auriculaire" data-hand="right" style="--size: 1;">
				<div>R</div>
			</keyboard-key>
		</keyboard-row>
		<keyboard-legend>Rangée du milieu en <Ergopti></Ergopti></keyboard-legend>
	</keyboard>
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
		un pouce a plus de force qu’un index, qui a plus de force qu’un majeur, qui a plus de force
		qu’un annulaire, qui a plus de force qu’un auriculaire. Il est facile de s’en rendre compte :
		presser fort de l’index sur une table, puis tenter de faire de même avec son auriculaire met en
		lumière cette différence.
	</p>
	<p>
		Par conséquent, ce constat de la force des doigts pris en compte, les meilleurs emplacements
		sont ceux sur la rangée de repos, en partant de l’index pour aller vers l’annulaire. Puis, les
		meilleurs emplacements seront sur les touches au-dessus et en-dessous de la rangée de repos, en
		partant là encore de l’index pour aller vers l’annulaire.
	</p>
	<!-- <p style="text-align:center; color:red;">
			[METTRE ICI UN CLAVIER VIDE MONTRANT LES MEILLEURS EMPLACEMENTS EN COULEUR]
		</p> -->

	<tiny-space></tiny-space>

	<p>
		La rangée des chiffres est donc encore moins accessible, car il faut traverser deux rangées
		depuis la rangée de repos pour l’atteindre. C’est pour cette raison que laisser le <kbd>É</kbd>
		sur cette ligne comme en AZERTY est une très mauvaise idée, car cette lettre est beaucoup utilisée
		en français. Par exemple, en français, le <kbd>É</kbd> est environ 2 fois plus fréquent que le
		<kbd>J</kbd>, dont la touche est pourtant en AZERTY sur l’un des meilleurs emplacements du
		clavier : la touche de repos de l’index.
	</p>
	<p>
		Enfin, contrairement à BÉPO ou Optimot, <Ergopti /> ne place pas de symboles de programmation ou
		de ponctuation sur la rangée des chiffres. Ces symboles sont ramenés au plus près des doigts grâce
		à l’utilisation de la couche <kbd>AltGr</kbd>.
	</p>

	<tiny-space></tiny-space>
	<KeyboardBasis id="frequences" />
	<tiny-space></tiny-space>

	<p>
		Comme le montre le clavier ci-dessus, les lettres les plus fréquentes sont bien sur la rangée du
		milieu en <Ergopti />. Effectivement, la lettre la plus fréquente, le <kbd>E</kbd>, est en
		rouge. Viennent ensuite en orange les voyelles et consonnes les plus fréquentes. Enfin, les
		lettres en vert, voire bleu, sont les moins fréquentes de toutes.
	</p>
	<p>
		Attention toutefois, car ces fréquences vont varier selon le texte analysé et la langue de
		celui-ci. Vous trouverez plus de détails sur la page <a href="/benchmarks" class="link"
			>Benchmarks</a
		>.
	</p>
</section>
