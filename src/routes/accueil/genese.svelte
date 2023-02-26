<script>
	import Nom from '$lib/composants/Nom.svelte';
	import Nom_Plus from '$lib/composants/Nom_Plus.svelte';
	import SFB from '$lib/composants/SFB.svelte';
	import EnsembleClavier from '$lib/composants/clavier/Ensemble_Clavier.svelte';
</script>

<h2>Genèse et raison des choix</h2>
<section>
	<p>
		Les améliorations d’Optimot par rapport au Bépo sont vraiment significatives. Les tests sont
		sans appel et montrent notamment une nette diminution des bigrammes à un doigt (SFBs).
	</p>
	<p>
		Après beaucoup d’hésitation à passer du Bépo à Optimot, j’ai voulu d’abord être certain que
		l’apprentissage de cette nouvelle disposition serait le dernier. C’est pourquoi j’ai décidé de
		regarder par moi-même si Optimot pouvait éventuellement encore être améliorée avant de faire mon
		choix.
	</p>
	<p>
		La réponse a été « oui ». Évidemment, la disposition <Nom /> a été optimisée selon mes critères qui
		ne seront probablement pas les votres. Toutefois, cela vous donnera probablement des idées si vous
		comptez choisir une nouvelle disposition voire en créer une.
	</p>
	<ul class="paragraphe">
		<li>Bépo, puis Optimot, puis Optim7 puis HyperTexte</li>
		<li>E sur le majeur et non l’index à cause des roulements et <SFB />s</li>
		<li>Q puis P puis W sur l’index gauche</li>
		<li>É sur l’index, puis création de la touche ★</li>
		<li>Comment retenir les symboles en AltGr</li>
	</ul>
	<p>
		La première étape dans la création d’<Nom /> a été de classer les touches du clavier en deux groupes
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
		La deuxième étape dans la création de la disposition a été de placer les touches les plus
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
