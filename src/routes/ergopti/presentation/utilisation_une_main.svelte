<script>
	import Ergopti from '#lib/components/Ergopti.svelte';
	import ErgoptiPlus from '#lib/components/ErgoptiPlus.svelte';
	import SFB from '#lib/components/SFB.svelte';

	import KeyboardBasis from '#lib/keyboard/KeyboardBasis.svelte';
</script>

<section>
	<h2>Optimisation pour l’utilisation à&nbsp;une&nbsp;main</h2>

	<p>
		Lors de l’utilisation d’un ordinateur, la plupart du temps la souris est tenue de la main droite
		et la main gauche repose près de la partie gauche du clavier. Quand vient le moment de taper sur
		une touche ou de réaliser une combinaison de touches pour faire un raccourci, il est bien
		souvent nécessaire de bouger la main droite. Celle-ci doit se déplacer de la souris à la partie
		droite du clavier, taper dessus, puis retourner à la souris pour continuer la navigation.
	</p>
	<p>
		Une bonne disposition clavier permet donc de faire beaucoup d’actions courantes avec la seule
		main gauche, <strong>sans lâcher la souris</strong>. Sur ce point, AZERTY est très bon :
		<kbd>X</kbd>, <kbd>C</kbd>, <kbd>V</kbd> et beaucoup d’autres lettres des raccourcis avec
		<kbd>Ctrl</kbd> sont du côté gauche.
	</p>

	<h3>
		Conservation des raccourcis <kbd>Ctrl</kbd> + <kbd>X</kbd>, <kbd>C</kbd>, <kbd>V</kbd> et
		<kbd>Z</kbd>
	</h3>

	<KeyboardBasis id="controle" />
	<tiny-space></tiny-space>
	<p>
		Les raccourcis <kbd-output>Ctrl</kbd-output> + <kbd-output>X</kbd-output>,
		<kbd-output>Ctrl</kbd-output>
		+ <kbd-output>C</kbd-output>,
		<kbd-output>Ctrl</kbd-output>
		+ <kbd-output>V</kbd-output> et <kbd-output>Ctrl</kbd-output> + <kbd-output>Z</kbd-output>
		sont conservés à gauche avec <Ergopti></Ergopti>. Cela permet de les réaliser sans avoir à
		bouger la main droite. Ils sont respectivement en <kbd>Ctrl</kbd> + <kbd>Ê</kbd>,
		<kbd>Ctrl</kbd>
		+
		<kbd>É</kbd>,
		<kbd>Ctrl</kbd>
		+ <kbd>À</kbd> et <kbd>Ctrl</kbd> + <kbd>È</kbd>.
	</p>

	<h3>Touches de raccourci sur la version Ergodox</h3>
	<KeyboardBasis id="raccourcis_ergodox" />
	<tiny-space></tiny-space>
	<p>
		La version d’<Ergopti /> adaptée aux claviers de type Ergodox est complètement optimisée pour l’utilisation
		à une main, car des touches <kbd>Copier</kbd>, <kbd>Coller</kbd>, <kbd>Couper</kbd> et
		<kbd>Alt+Tab</kbd> ont été directement incluses à gauche du clavier. À noter que ces touches ne sont
		pas définies dans le pilote et que ce sont uniquement des idées d’implémentation. Les claviers de
		type Ergodox peuvent en effet être programmés pour ajouter et déplacer des touches.
	</p>

	<h3>Touches de raccourci sur la version ISO</h3>
	<p>
		La version ISO (pour claviers standards) ne peut malheureusement pas avoir les touches de
		raccourci de la version Ergodox. Les touches à sa gauche sont déjà prises par
		<kbd>Shift</kbd>, <kbd>CapsLock</kbd> et <kbd>Tab</kbd>, alors que sur l’Ergodox, ces 3 touches
		peuvent aller sous les pouces.
	</p>
	<p>
		<ErgoptiPlus /> donne toutefois un moyen de contourner les limites de la version ISO grâce à un
		<strong>mécanisme de tap-hold</strong>. L’idée du tap-hold est qu’il est possible d’assigner
		deux actions à une même touche : une au tap (appui bref) et une au hold (maintenir pressé).
		Ainsi, presser puis relâcher un modificateur envoie un raccourci, mais le maintenir avec une
		autre touche garde son rôle habituel. Cela permet d’intégrer des touches
		<kbd-output>Copier</kbd-output>, <kbd-output>Coller</kbd-output> et
		<kbd-output>Alt+Tab</kbd-output>
		respectivement sur
		<kbd>LShift</kbd>, <kbd>LCtrl</kbd> et <kbd>Alt</kbd>. En outre, un layer de navigation ainsi
		que les touches
		<kbd>Backspace</kbd>
		et <kbd>Entrée</kbd> sont également disponibles à gauche du clavier avec <ErgoptiPlus
		></ErgoptiPlus>.
	</p>
</section>
