<script>
	import Ergopti from '$lib/components/Ergopti.svelte';
	import ErgoptiPlus from '$lib/components/ErgoptiPlus.svelte';
	import SFB from '$lib/components/SFB.svelte';
</script>

<section>
	<h2 class="first-h2">Genèse et inspirations</h2>
	<p>
		La genèse de la disposition <Ergopti></Ergopti> remonte à début 2022, suite à la découverte de la
		disposition
		<a href="https://optimot.fr/" target="_blank" class="link">Optimot</a>. À ce moment-là, j’étais
		un utilisateur du
		<a href="https://bepo.fr/" target="_blank" class="link">BÉPO</a>
		depuis déjà de nombreuses années. Les améliorations d’Optimot par rapport au BÉPO sont significatives,
		avec notamment une forte diminution des bigrammes à un doigt (<SFB />s) et un meilleur placement
		des lettres pour l’anglais. Cependant, l'idée d'apprendre Optimot, pour peut-être découvrir par
		la suite une disposition encore meilleure, était peu attrayante.
	</p>
	<p>
		Pour m’assurer de ne pas avoir à passer mon temps à apprendre de nouvelles dispositions, toutes
		meilleures les unes que les autres, la solution a été radicale : développer la mienne, optimisée
		pour mes besoins. Évidemment, une telle tâche nécessite un investissement en temps considérable.
		Il faut déjà comprendre ce qui fait une bonne disposition, puis réarranger les touches pour en
		créer une au moins aussi bonne, si ce n’est meilleure, que les autres dispositions déjà
		disponibles. Enfin, il faut tester soi-même la disposition, car certains défauts n’apparaissent
		pas toujours sur un analyseur théorique. Et pour la tester, il faut réapprendre totalement à
		taper au clavier, et ce à chaque fois que l’on essaie une nouvelle disposition.
	</p>

	<tiny-space></tiny-space>

	<p>
		Les premières versions de ce projet, baptisées <strong
			><a href="https://bepo.fr/wiki/Utilisateur:Adrien_Moyaux" target="_blank" class="link"
				>Optim7</a
			></strong
		>, étaient des dérivés directs d’Optimot. L'objectif initial était d’améliorer les scores sur
		les analyseurs de disposition et de corriger des choix qui ne me convenaient pas. Par exemple,
		je voulais les chiffres en accès direct, ce qui n’est pas le cas en Optimot, son créateur
		préférant y mettre les symboles.
	</p>
	<p>
		Rapidement, <Ergopti></Ergopti> s’éloigna d’Optimot sur plusieurs aspects fondamentaux. L'un des
		points clés était ma volonté d'optimiser les <em>roulements</em>, entraînant de nombreux essais
		d’arrangements des touches pour la <em>homerow</em>, notamment sur la partie droite avec les
		consonnes. Un des choix majeurs fut de privilégier un agencement <kbd>SNTR</kbd> plutôt que le
		<kbd>TSRN</kbd>
		du BÉPO et d’Optimot. En effet, le bigramme <kbd>NT</kbd> est le plus fréquent des bigrammes
		consonne-consonne, et il est pertinent de l'optimiser pour qu'il se réalise sur des doigts
		consécutifs. D’autant que <kbd>NTR</kbd> se réalise également en roulement.
	</p>
	<p>
		L’agencement final des quatre lettres de la rangée principale droite a donc été soigneusement
		conçu pour maximiser les bigrammes consonantiques, pour une frappe harmonieuse. Seuls les
		bigrammes <kbd>ST</kbd>
		et <kbd>TS</kbd> (comme dans « <kbd>ST</kbd>A<kbd>TS</kbd> ») ne profitent malheureusement pas
		de cette optimisation des roulements, car il était impossible de tout avoir en même temps. En
		résumé, <Ergopti></Ergopti> a été
		<strong
			>pensée dès le départ pour maximiser les roulements, mais sans sacrifier l’alternance des
			mains</strong
		>. La disposition a la même alternance des mains que BÉPO ou Optimot, tout en ayant des
		roulements largement plus fréquents pour les lettres ne bénéficiant pas de cette alternance.
	</p>

	<tiny-space></tiny-space>

	<p>
		La disposition a beaucoup évoluée au fil du temps. En particulier, la touche sur l’index gauche
		a plusieurs fois changé :
		<kbd>Q</kbd>, puis <kbd>P</kbd>, puis <kbd>W</kbd> et enfin la création d’une touche spéciale
		<kbd>★</kbd>
		et le déplacement de <kbd>É</kbd> sur l’annulaire gauche.
	</p>
	<p>
		Bien que la création d’<Ergopti></Ergopti> ait été un processus étalé sur plusieurs années, près
		de 90% de la disposition est restée constante. Les ajustements concernaient principalement le déplacement
		de certaines lettres, nécessitant ainsi de petites phases de réapprentissage régulières. Néanmoins,
		la plupart des changements se sont avérés non pertinents, ce qui explique l'absence de modifications
		majeures entre les premières versions d’<strong>Optim7</strong> et la version finale d’<Ergopti
		></Ergopti>.
	</p>

	<tiny-space></tiny-space>

	<p>
		À un certain stade de développement, il devint évident que la disposition
		<strong>Optim7</strong> n'était plus une simple variante d’Optimot. Le besoin de renommer ce
		projet s’est alors imposé. Grâce à la suggestion d’un utilisateur nommé
		<strong>Zigmund</strong> sur Discord, après avoir longtemps cherché avec lui un nom aussi
		remarquablement bien trouvé que celui d’Optimot, le nom
		<strong>HyperTexte</strong> fut d’abord retenu. Cependant, il s’avéra par la suite que ce nom était
		mal choisi, car déjà utilisé sur de nombreux sites ailleurs (ce qui n’est pas étonnant, avec toutes
		les mentions de « lien hypertexte »). La découverte de la disposition, notamment grâce à un moteur
		de recherche, s’en trouvait compromise. Le site de présentation n’apparaissait même pas en première
		page des résultats.
	</p>
	<p>
		Environ un mois après la sortie publique de la disposition,
		<strong>HyperTexte</strong> fut renommée <Ergopti></Ergopti>, son nom définitif. Ce nouveau nom
		reflète à la fois l’ergonomie de la disposition et l’optimisation de celle-ci, la lettre
		<kbd>O</kbd> faisant le lien entre les deux (ergo[nomie] & opti[misation]). En outre, il est
		court, d’une longueur idéale de 7 lettres, et peu présent en ligne. Une fois la nouvelle
		appellation trouvée, le nom de domaine
		<a href="https://ergopti.fr" class="link">https://ergopti.fr</a> fut également réservé à ce moment-là.
	</p>

	<h3>Comment la disposition a été développée</h3>
	<p>
		<i class="icon-circle-1"><span class="path1"></span><span class="path2"></span></i> La première
		étape dans la création d’<Ergopti /> a été de partager les touches du clavier en deux groupes : main
		gauche et main droite. L’objectif est de maximiser l’alternance des mains, c’est-à-dire de faire
		en sorte que les touches qui sont le plus souvent tapées l’une après l’autre le soient par des mains
		différentes.
	</p>
	<p>
		Pour optimiser ce critère, les voyelles ont toutes été placées d’un côté du clavier. Celles-ci
		étant majoritairement précédées et suivies de consonnes, cela amène immédiatement une grande
		alternance des mains. À noter que cette idée est loin d’être nouvelle, car elle est déjà
		appliquée dans presque toutes les dispositions alternatives : Dvorak, BÉPO, Optimot, etc.
	</p>
	<p>
		Dans le cas d’<Ergopti />, les voyelles ont été placées sur le côté gauche. La raison est que
		sur la plupart des claviers standards, il y a moins de touches sur ce côté. Le côté droit a en
		effet trois colonnes de touches pour l’auriculaire alors que l’auriculaire gauche n’en a qu’une.
		Ces nombreux emplacements sont précieux, surtout pour les langues ayant besoin de caractères
		supplémentaires, comme les accents en français. Le nombre de consonnes étant largement supérieur
		au nombre de voyelles, même en comptant les voyelles accentuées du français, les placer du côté
		avec le plus de touches était logique.
	</p>
	<p>
		Le seul problème avec cette approche est que l’on perd des raccourcis utiles sur la main gauche
		qui se font avec des consonnes, comme <kbd>Ctrl</kbd> + <kbd>C</kbd> pour copier ou
		<kbd>Ctrl</kbd> + <kbd>V</kbd> pour coller. Cependant, <Ergopti></Ergopti> a une solution pour que
		ce ne soit pas un problème en dupliquant ces raccourcis sur les voyelles accentuées.
	</p>

	<tiny-space></tiny-space>

	<p>
		<i class="icon-circle-2"><span class="path1"></span><span class="path2"></span></i> La deuxième
		étape dans la création de la disposition a été de placer les touches les plus souvent utilisées
		le plus proche possible des doigts. Les doigts sont effectivement toujours censés reposer sur la
		rangée de repos du clavier (la ligne du milieu, aussi appelée <em>homerow</em>). Il est donc
		naturel de chercher à placer sur cette rangée les lettres les plus utilisées pour réduire les
		déplacements de doigts aux touches.
	</p>
	<p>
		De même, certaines touches sont plus facilement accessibles que d’autres sur les claviers
		standards à cause de la longueur des doigts. Par exemple, la touche <kbd>C</kbd> en
		AZERTY/QWERTY est plus accessible que la touche <kbd>R</kbd>, car il est plus aisé de déplacer
		l’index gauche vers le bas que vers le haut. Ainsi, les touches les plus utilisées ont été
		placées sur la rangée de repos, et les autres lettres ont été placées sur les autres lignes en
		fonction de leur accessibilité.
	</p>

	<tiny-space></tiny-space>

	<p>
		<i class="icon-circle-3"><span class="path1"></span><span class="path2"></span></i> La troisième
		étape a été de déplacer des lettres pour réduire au maximum le nombre de <SFB />s et de ciseaux,
		tout en maximisant les roulements. Encore une fois, la maximisation des roulements était la
		priorité dès le début du projet.
	</p>
	<p>
		Cette étape a été la plus difficile, car intervertir seulement deux touches peut transformer une
		disposition excellente en une disposition très moyenne. Il faut effectivement avoir en tête les
		bigrammes les plus fréquents et s’assurer que déplacer une touche à un autre emplacement ne va
		pas empirer la situation.
	</p>

	<h3>
		Simplification et utilisation de la couche <kbd>AltGr</kbd>
	</h3>
	<p>
		<Ergopti /> utilise intensivement la couche <kbd>AltGr</kbd>. Celle-ci permet de réduire
		drastiquement les distances parcourues pour atteindre de nombreuses touches. N’ayant nullement
		besoin de tous les caractères exotiques et touches mortes du BÉPO ou d’Optimot, la majeure
		partie fut supprimée pour ne conserver que l’essentiel. Cette simplification permit de libérer
		de nombreux excellents emplacements sur la couche <kbd>AltGr</kbd> et laissa assez de place pour
		y loger tous les symboles. Ainsi, plus besoin d’étendre les doigts pour atteindre la rangée des chiffres
		pour taper des parenthèses, guillemets ou opérateurs mathématiques. Au contraire, tous ces symboles
		sont désormais sous les doigts, sur les trois rangées principales du clavier.
	</p>
	<p>
		En outre, les chiffres sont quant à eux passés en accès direct, un changement très appréciable
		lors de l'utilisation quotidienne. C’est une fois avoir passé les chiffres en accès direct que
		l’on se rend compte de l’énorme gain de confort que cela procure et l’on se demande pourquoi on
		n’avait pas cela plus tôt. Pourtant, même BÉPO, qui est déjà largement plus optimisé qu’AZERTY,
		ne le propose pas, pas plus qu’Optimot. D’ailleurs, en dehors des dispositions françaises, la
		plupart des dispositions alternatives proposent les chiffres en accès direct, comme Dvorak,
		Colemak, Neo, etc. Même le QWERTY américain propose les chiffres en accès direct, ce qui est un
		comble pour cette disposition qui est l’une des moins optimisées au monde.
	</p>

	<h3>
		Atouts d’<ErgoptiPlus></ErgoptiPlus>
	</h3>
	<p>
		La singularité d’<Ergopti></Ergopti> ne réside pas seulement dans ses excellents scores en français,
		anglais et en programmation, où elle rivalise avec les meilleures dispositions actuelles. Sa version
		étendue,
		<ErgoptiPlus></ErgoptiPlus>, pousse encore plus loin l’efficacité de cette disposition déjà très
		performante, en la rendant véritablement exceptionnelle.
	</p>
	<p>
		Le qualificatif d’exceptionnel n’est pas exagéré : <ErgoptiPlus></ErgoptiPlus> permet, une fois maîtrisée,
		de supprimer presque totalement les <SFB></SFB>s, y compris ceux liés à la répétition d'une même
		touche. Cela est rendu possible grâce à la touche spéciale <kbd class="glow">★</kbd>, permettant
		de réitérer la frappe de la touche précédente avec une fluidité inédite, ainsi qu’à la touche
		<kbd>,</kbd>
		de réduction des <SFB></SFB>s.
	</p>
	<p>
		Il convient de préciser que l’idée de cette touche de répétition ne vient pas d’<Ergopti
		></Ergopti>. Elle provient d'une (voire plus) disposition anglophone. D'autres concepts ont
		également été empruntés, comme l'utilisation d'AHK (AutoHotkey) dans la disposition
		<a href="https://ballerboo.github.io/boolayout/" target="_blank" class="link">Boo</a> afin de modifier
		le comportement des combinaisons de touches. Ce système permet d'optimiser encore davantage les roulements
		sur des touches adjacentes qui n'engendrent pas de bigrammes habituels.
	</p>
	<p>
		C’est ainsi que l’on peut avoir à la fois les roulements <kbd>CH</kbd>, <kbd>WH</kbd> et
		<kbd>OW/WO</kbd>, grâce à ce mécanisme appliqué à la lettre <kbd>W</kbd>. Avoir les roulements
		<kbd>CH</kbd>
		et <kbd>WH</kbd> a depuis le début été un objectif, car ces deux combinaisons sont très fréquentes.
		Les avoir en roulement offre un confort exceptionnel.
	</p>
</section>
