<script>
	import Nom from '$lib/composants/Nom.svelte';
	import NomPlus from '$lib/composants/NomPlus.svelte';
	import SFB from '$lib/composants/SFB.svelte';
	import BlocClavier from '$lib/clavier/BlocClavier.svelte';
	import { taperTexte } from '$lib/clavier/taperTexte.js';
	import AlternanceMains from './alternance_mains.svelte';
	import DistanceDoigtsTouches from './distance_doigts_touches.svelte';
</script>

<section>
	<h2 data-aos="fade-up" data-aos-mirror="true">Distance des doigts aux touches</h2>
	<div class="content">
		<h3 data-aos="fade-right" data-aos-mirror="true">Optimisation de la rangée du milieu</h3>

		<p>
			Lors de l’apprentissage de la dactylographie, il est enseigné que les doigts doivent reposer
			sur la rangée du milieu (<kbd>QSDF</kbd>
			et <kbd>JKLM</kbd> en AZERTY). En particulier, il y a souvent une petite bosse sur les touches
			de repos pour les index, qui sont donc <kbd>F</kbd> et <kbd>J</kbd> en AZERTY.
		</p>
		<p class="text-gray">
			➜ L’idée est de taper sur une touche, puis de tout de suite replacer le doigt sur la rangée du
			milieu. Cela permet de toujours être capable de bouger rapidement dans n’importe quelle
			direction, un peu comme un sportif se replace toujours au milieu du terrain au cours d’un
			match.
		</p>
		<p>
			Il est alors logique de se dire que nos doigts étant la plupart du temps sur la rangée du
			milieu, autant y placer les lettres les plus fréquemment utilisées. En procédant ainsi, il n’y
			a presque plus besoin de bouger les doigts, juste à presser les lettres de la rangée de repos
			et parfois atteindre la rangée supérieure ou inférieure pour les lettres les moins fréquentes.
		</p>
		<bloc-clavier data-couleur="azerty">
			<bloc-ligne class="center">
				<bloc-touche data-doigt="auriculaire" data-main="gauche" style="--taille: 1;"
					><div>Q</div></bloc-touche
				>
				<bloc-touche data-doigt="annulaire" data-main="gauche" style="--taille: 1;"
					><div>S</div></bloc-touche
				>
				<bloc-touche data-doigt="majeur" data-main="gauche" style="--taille: 1;"
					><div>D</div></bloc-touche
				>
				<bloc-touche data-doigt="index" data-main="gauche" style="--taille: 1;"
					><div>F</div></bloc-touche
				>
				<div style="display: inline-block; width: 50px;" />
				<bloc-touche data-doigt="index" data-main="droite" style="--taille: 1;"
					><div>J</div></bloc-touche
				>
				<bloc-touche data-doigt="majeur" data-main="droite" style="--taille: 1;"
					><div>K</div></bloc-touche
				>
				<bloc-touche data-doigt="annulaire" data-main="droite" style="--taille: 1;"
					><div>L</div></bloc-touche
				>
				<bloc-touche data-doigt="auriculaire" data-main="droite" style="--taille: 1;"
					><div>M</div></bloc-touche
				>
			</bloc-ligne>
			<legende-clavier>Rangée du milieu en AZERTY</legende-clavier>
		</bloc-clavier>

		<p>
			Pourtant, le QWERTY est pire qu’une disposition aléatoire sur ce point. <span
				class="text-gray"
				>La légende raconte que sa première rangée remonte à l’époque de l’invention de la machine à
				écrire. Le choix de la disposition QWERTY aurait, entre autres raisons, été influencé par un
				aspect purement marketing. En effet, à des fins de démonstrations, ont été placées sur la
				rangée supérieure de la machine à écrire toutes les lettres nécessaires pour pouvoir écrire <kbd-sortie
					>TYPEWRITER</kbd-sortie
				>.</span
			>
		</p>
		<p>
			Certaines des touches ayant les fréquences d’apparition les plus rares (en français et en
			anglais) sont sur ces excellents emplacements tels que le <kbd>Q</kbd>, le <kbd>F</kbd>, le
			<kbd>J</kbd>
			et le
			<kbd>K</kbd>. Pire, la quasi-totalité des touches les plus utilisées se retrouvent en fait sur
			la rangée du dessus (<kbd>AZERTYUIOP</kbd>). C’est notamment le cas de toutes les voyelles,
			dont le nombre est faible comparé au nombre de consonnes, mais qui sont toutefois
			incontournables pour l’écriture de chaque mot.
		</p>

		<bloc-clavier data-couleur="hypertexte">
			<bloc-ligne class="center">
				<bloc-touche data-doigt="auriculaire" data-main="gauche" style="--taille: 1;"
					><div>A</div></bloc-touche
				>
				<bloc-touche data-doigt="annulaire" data-main="gauche" style="--taille: 1;"
					><div>I</div></bloc-touche
				>
				<bloc-touche data-doigt="majeur" data-main="gauche" style="--taille: 1;"
					><div>E</div></bloc-touche
				>
				<bloc-touche data-doigt="index" data-main="gauche" style="--taille: 1;"
					><div>U</div></bloc-touche
				>
				<div style="display: inline-block; width: 50px;" />
				<bloc-touche data-doigt="index" data-main="droite" style="--taille: 1;"
					><div>S</div></bloc-touche
				>
				<bloc-touche data-doigt="majeur" data-main="droite" style="--taille: 1;"
					><div>N</div></bloc-touche
				>
				<bloc-touche data-doigt="annulaire" data-main="droite" style="--taille: 1;"
					><div>T</div></bloc-touche
				>
				<bloc-touche data-doigt="auriculaire" data-main="droite" style="--taille: 1;"
					><div>R</div></bloc-touche
				>
			</bloc-ligne>
			<legende-clavier>Rangée du milieu en HyperTexte</legende-clavier>
		</bloc-clavier>

		<p>
			En français et en anglais, le <kbd>E</kbd>
			est de loin la lettre la plus fréquente. Viennent ensuite les voyelles <kbd>A</kbd>,
			<kbd>I</kbd>, <kbd>O</kbd> et <kbd>U</kbd>, ainsi que les consonnes
			<kbd>S</kbd>, <kbd>N</kbd>, <kbd>T</kbd> et <kbd>R</kbd>. <Nom /> place évidemment les lettres
			les plus utilisées sur la rangée du milieu. En résulte immédiatement un déplacement des doigts
			largement diminué et un meilleur confort.
		</p>
		<h3 data-aos="fade-right" data-aos-mirror="true">Optimisation selon la force des doigts</h3>
		<p>
			Une fois que les lettres les plus fréquentes ont été placées sur la rangée du milieu, il reste
			encore beaucoup à faire. En effet, <span class="important"
				>chaque doigt a une force différente</span
			>.
			<span class="text-gray"
				>Ainsi, un pouce a plus de force qu’un index, qui a plus de force qu’un majeur, qui a plus
				de force qu’un annulaire, qui a plus de force qu’un auriculaire. Vous pouvez facilement vous
				en rendre compte en pressant fort de l’index sur une table, puis en essayant de faire de
				même avec votre auriculaire.</span
			>
		</p>
		<p>
			Par conséquent, ce constat de la force des doigts pris en compte, les meilleurs emplacements
			sont ceux sur la rangée de repos, en partant de l’index pour aller vers l’annulaire. Puis, les
			meilleurs emplacements seront sur les touches au-dessus et en-dessous de la rangée de repos,
			en partant là encore de l’index pour aller vers l’annulaire.
		</p>
		<!-- <p style="text-align:center; color:red;">
			[METTRE ICI UN CLAVIER VIDE MONTRANT LES MEILLEURS EMPLACEMENTS EN COULEUR]
		</p> -->
		<p>
			La rangée des chiffres est donc encore moins accessible, car il faut traverser deux rangées
			depuis la rangée de repos pour l’atteindre. C’est pour cette raison que laisser le <kbd>É</kbd
			>
			sur cette ligne comme en AZERTY est une très mauvaise idée, car cette lettre est beaucoup utilisée
			en français. Par exemple, en français, le <kbd>É</kbd> est 5 fois plus fréquent que le
			<kbd>J</kbd>, dont la touche est pourtant en AZERTY sur l’un des meilleurs emplacements du
			clavier : la touche de repos de l’index.
		</p>
		<p>
			Enfin, contrairement au BÉPO ou à l’Optimot, <Nom /> ne place pas de symboles de programmation
			ou de ponctuation sur la rangée des chiffres. Ces symboles sont ramenés au plus près des doigts
			grâce à l’utilisation de la couche <kbd>AltGr</kbd>.
		</p>

		<mini-espace />

		<BlocClavier clavier="frequences" />

		<p>
			Comme vous pouvez le constater sur le clavier ci-dessus, les lettres les plus fréquentes sont
			bien sur la rangée du milieu en <Nom />. Effectivement, la lettre la plus fréquente, le
			<kbd>E</kbd>, est en rouge. Viennent ensuite en orange les voyelles et consonnes les plus
			fréquentes. Enfin, les lettres en vert, voire bleu, sont les moins fréquentes de toutes.
		</p>
		<p>
			Attention toutefois, car ces fréquences vont varier selon le texte analysé et la langue de
			celui-ci. Vous trouverez plus de détails sur la page <a href="/benchmarks">Benchmarks</a>.
		</p>
	</div>
</section>
