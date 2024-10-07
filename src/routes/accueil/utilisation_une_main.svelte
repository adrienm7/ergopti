<script>
	import Nom from '$lib/composants/Nom.svelte';
	import NomPlus from '$lib/composants/NomPlus.svelte';
	import SFB from '$lib/composants/SFB.svelte';

	import BlocClavier from '$lib/clavier/BlocClavier.svelte';
</script>

<section>
	<h2 data-aos="zoom-out" data-aos-mirror="true">Optimisation pour l’utilisation à une main</h2>

	<div class="content">
		<p>
			Lors de l’utilisation d’un ordinateur, la plupart du temps la souris est tenue de la main
			droite et la main gauche repose près de la partie gauche du clavier. Quand vient le moment de
			taper sur une touche ou de réaliser une combinaison de touches pour faire un raccourci, il est
			bien souvent nécessaire de bouger la main droite. Celle-ci doit se déplacer de la souris à la
			partie droite du clavier, taper dessus, puis retourner à la souris pour continuer la
			navigation.
		</p>
		<p>
			Par conséquent, il est également important de s’assurer que, grâce à sa disposition clavier,
			beaucoup d’actions courantes puissent se réaliser avec la seule main gauche afin de <span
				class="important">ne pas avoir à lâcher la souris</span
			>. À noter que sur ce point AZERTY est très bon car <kbd>X</kbd>, <kbd>C</kbd>, <kbd>V</kbd>
			et de nombreuses autres lettres fréquemment utilisées pour faire des raccourcis en combinaison
			avec <kbd>Ctrl</kbd> sont du côté gauche.
		</p>
		<p>
			Avec <Nom />, le <kbd>=</kbd> a ainsi été dupliqué à gauche pour être mis en accès direct.
			Cela permet de faire facilement les raccourcis sur Excel comme <kbd>=</kbd> et
			<kbd>Alt</kbd>
			+
			<kbd>=</kbd>. En effet, normalement le <kbd>=</kbd> se situe en <kbd>AltGr</kbd> +
			<kbd>L</kbd>.
		</p>
		<mini-espace />
		<BlocClavier nom="controle" />
		<mini-espace />
		<p>
			Les raccourcis <kbd-sortie>Ctrl</kbd-sortie> + <kbd-sortie>X</kbd-sortie>,
			<kbd-sortie>Ctrl</kbd-sortie>
			+ <kbd-sortie>C</kbd-sortie>,
			<kbd-sortie>Ctrl</kbd-sortie>
			+ <kbd-sortie>V</kbd-sortie> et <kbd-sortie>Ctrl</kbd-sortie> + <kbd-sortie>Z</kbd-sortie>
			sont également conservés à gauche. Cela permet de les réaliser sans avoir à bouger la main droite.
			Ils sont respectivement en <kbd>Ctrl</kbd> + <kbd>Ê</kbd>, <kbd>Ctrl</kbd> +
			<kbd>É</kbd>,
			<kbd>Ctrl</kbd>
			+ <kbd>À</kbd> et <kbd>Ctrl</kbd> + <kbd>È</kbd>
		</p>

		<h3 data-aos="fade-right" data-aos-mirror="true">
			Touches de raccourci sur la version Ergodox
		</h3>
		<p>
			La version d’<Nom /> adaptée aux claviers de type Ergodox est complètement optimisée pour l’utilisation
			à une main, car des touches <kbd>Copier</kbd>, <kbd>Coller</kbd>, <kbd>Couper</kbd> et
			<kbd>Alt+Tab</kbd> ont été directement incluses à gauche du clavier. À noter que ces touches ne
			sont pas définies dans le pilote et que ce sont uniquement des idées d’implémentation. Les claviers
			de type Ergodox peuvent en effet être programmés pour ajouter et déplacer des touches.
		</p>

		<h3 data-aos="fade-right" data-aos-mirror="true">Touches de raccourci sur la version ISO</h3>
		<p>
			La version ISO (pour claviers standards) ne peut quant à elle malheureusement pas bénéficier
			des touches de raccourci de la version Ergodox, car les touches à sa gauche sont déjà occupées
			par les touches
			<kbd>Shift</kbd>, <kbd>"Capslock"</kbd> et <kbd>Tab</kbd> contrairement à l’Ergodox où l’on peut
			placer ces 3 touches sous les pouces.
		</p>
		<p>
			<NomPlus /> donne toutefois le moyen de contourner les limites de la version ISO grâce à un
			<span class="important">mécanisme de tap-hold</span>. L’idée du tap-hold est qu’il est
			possible d’assigner deux actions à une même touche : une au tap (appui bref) et une au hold
			(maitenir pressé). Grâce au tap-hold, il est possible d’avoir le comportement suivant : taper
			une touche envoie un raccourci, mais la presser la fait se comporter normalement. Cela permet
			d’intégrer des touches
			<kbd>Copier</kbd>, <kbd>Coller</kbd> et <kbd>Alt+Tab</kbd> respectivement sur
			<kbd>LShift</kbd>, <kbd>LCtrl</kbd> et <kbd>Alt</kbd>.
		</p>
	</div>
</section>
