<script>
	import Nom from '$lib/composants/Nom.svelte';
	import Nom_Plus from '$lib/composants/Nom_Plus.svelte';
	import SFB from '$lib/composants/SFB.svelte';
	import EnsembleClavier from '$lib/composants/clavier/Ensemble_Clavier.svelte';
</script>

<h2>Genèse et raison des choix</h2>
<h3>Genèse</h3>
<section>
	<p>
		Les améliorations de la disposition Optimot par rapport au BÉPO sont vraiment significatives.
		Les tests sont sans appel et montrent notamment une nette diminution des bigrammes à un doigt (<SFB
		/>s).
	</p>
	<p>
		J’ai eu beaucoup d’hésitations à passer du BÉPO, qui était la disposition que j’utilisais depuis
		plusieurs années, à Optimot. Avant de changer, j’ai voulu d’abord être certain que
		l’apprentissage de cette nouvelle disposition serait le dernier. C’est pourquoi j’ai décidé de
		regarder par moi-même si Optimot pouvait éventuellement encore être améliorée avant de faire mon
		choix.
	</p>
	<p>
		La réponse a été « oui ». Évidemment, la disposition <Nom /> a été optimisée selon mes critères ;
		ce ne seront peut-être pas totalements les vôtres. Toutefois, cela vous donnera probablement des
		idées si vous comptez choisir une nouvelle disposition voire en créer une.
	</p>
</section>
<h3>Historique des modifications</h3>
<section>
	<p>
		Au départ, ma disposition dérivée d’Optimot était nommée <em>Optim7</em>. Cependant, passé un
		certain cap, ce nom a été changé en <Nom />. La disposition a beaucoup évoluée au fil du temps.
		En particulier, la touche sur l’index gauche a plusieur fois changé :
		<kbd>Q</kbd>, puis <kbd>P</kbd>, puis <kbd>W</kbd> et enfin la création d’une touche spéciale
		<kbd>★</kbd> et de déplacement de <kbd>É</kbd> sur l’annulaire gauche.
	</p>
</section>

<h3>Comment la disposition a été créée</h3>
<section>
	<p>
		➀ La première étape dans la création d’<Nom /> a été de classer les touches du clavier en deux groupes
		: main gauche et main droite.
	</p>
	<p>
		Pour optimiser ce critère, les voyelles ont toutes été placées d’un côté du clavier. Celles-ci
		étant majoritairement précédées et suivies de consonnes, cela amène immédiatement une grande
		alternance des mains. À noter que cette idée est loin d’être nouvelle, car elle est déjà
		appliquée dans presque toutes les dispositions alternatives : Dvorak, BÉPO, etc.
	</p>
	<p>
		Dans le cas d’<Nom />, les voyelles ont été placées sur le côté gauche. La raison est que sur la
		plupart des claviers (i.e ceux qui sont non matriciels) il y a moins de touches sur ce côté. Le
		côté droit a en effet trois colonnes de touches pour l’auriculaire alors que l’auriculaire
		gauche n’en a qu’une. Ces nombreux emplacements sont précieux, surtout pour les langues ayant
		besoin de caractères supplémentaires comme les accents en français.
	</p>
	<p>
		➁ La deuxième étape dans la création de la disposition a été de placer les touches les plus
		souvent utilisées les plus proches possible des doigts. Les doigts sont effectivement toujours
		censés reposer sur la rangée de repos du clavier (la ligne du milieu). Il est donc logique de
		chercher à placer sur cette rangée les lettres les plus utilisées pour réduire les déplacements
		des doigts aux touches.
	</p>
</section>

<h3>Utilisation de la couche AltGr</h3>
<section>
	<p>
		<Nom /> utilise intensivement la couche <kbd>AltGr</kbd>. Celle-ci permet de réduire
		drastiquement les distances parcourues pour atteindre certaines touches. Un autre avantage est
		le fait que cette touche modificatrice est aisément atteingable par le pouce droit sur un
		clavier standard. Cela permet donc de mettre co doigt à contribution, contrairement à l’AZERTY.
	</p>
	<p>
		N’ayant nullement besoin de tous les caractères exotiques et touches mortes du Bépo et
		d’Optimot, j’en ai supprimé la majeure partie. Cela laisse assez de place pour ne plus avoir à
		atteindre la rangée des nombres pour taper des parenthèses, guillemets ou opérateurs
		mathématiques.
	</p>
	<p>
		Cela fait que je n’ai plus grande utilité des espaces insécables et espaces fines insécables.
		Celles-ci sont donc déplacées à un autre endroit pour me permettre d’avoir le tiret en
		Shift+Espace qui est beaucoup plus utile. L’underscore reste en AltGr+Espace.
	</p>
</section>
