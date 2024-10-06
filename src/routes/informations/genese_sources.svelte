<script>
	import Nom from '$lib/composants/Nom.svelte';
	import NomPlus from '$lib/composants/NomPlus.svelte';
	import SFB from '$lib/composants/SFB.svelte';
</script>

<section class="contenu">
	<h2 data-aos="zoom-out" data-aos-mirror="true">Genèse et sources</h2>
	<p>
		La genèse de la disposition <Nom></Nom> remonte à 2022, à la suite de la découverte d'Optimot. Les
		améliorations de la disposition Optimot par rapport au BÉPO sont vraiment significatives. Les tests
		sont sans appel et montrent notamment une nette diminution des bigrammes à un doigt (<SFB />s).
	</p>
	<p>
		Les premières versions de ce projet, baptisées Optim7, étaient des dérivés directs d'Optimot.
		L'objectif initial était de peaufiner légèrement les scores sur les analyseurs de dispositions
		existants. À cette époque, étant utilisateur de la disposition BÉPO, l'idée d'apprendre Optimot,
		pour peut-être découvrir encore une version améliorée par la suite, était peu attrayante. La
		meilleure façon de m’assurer de ne pas avoir à passer mon temps à apprendre de nouvelles
		dispositions était de créer la mienne, optimisée pour mes besoins, même si cela nécessitait un
		investissement en temps considérable.
	</p>
	<p>
		Rapidement, <Nom></Nom> s'est éloigné d'Optimot sur plusieurs aspects fondamentaux. L'un des points
		clés était ma volonté d'optimiser les <em>roulements</em>, entraînant de nombreux tests sur la
		disposition des touches principales, notamment sur la partie droite avec les consonnes. L'une
		des décisions majeures fut de privilégier un agencement SNTR plutôt que TSRN, car le bigramme NT
		est très fréquent, et il semblait pertinent de l'optimiser pour qu'il se réalise sur des doigts
		consécutifs. L’agencement final des quatre lettres de la rangée principale a été soigneusement
		conçu pour maximiser les bigrammes consonantiques, avec une disposition harmonieuse. Seuls les
		bigrammes ST et TS (comme dans "STaTS") ne profitent pas de cette optimisation en roulement.
	</p>
	<p>
		La disposition a beaucoup évoluée au fil du temps. En particulier, la touche sur l’index gauche
		a plusieurs fois changé :
		<kbd>Q</kbd>, puis <kbd>P</kbd>, puis <kbd>W</kbd> et enfin la création d’une touche spéciale
		<kbd>★</kbd>
		et de déplacement de <kbd>É</kbd> sur l’annulaire gauche.
	</p>
	<h3 data-aos="fade-right" data-aos-mirror="true">
		Simplification et utilisation de la couche <kbd>AltGr</kbd>
	</h3>
	<p>
		<Nom /> utilise intensivement la couche <kbd>AltGr</kbd>. Celle-ci permet de réduire
		drastiquement les distances parcourues pour atteindre certaines touches. Un autre avantage est
		le fait que cette touche modificatrice est aisément atteingable par le pouce droit sur un
		clavier standard. Cela permet donc de mettre ce doigt à contribution, contrairement à l’AZERTY
		qui ne l’exploite pas suffisamment.
	</p>
	<p>
		N’ayant nullement besoin de tous les caractères exotiques et touches mortes du BÉPO ou
		d’Optimot, j’en ai supprimé la majeure partie. Cela laisse assez de place pour ne plus avoir à
		atteindre la rangée des nombres pour taper des parenthèses, guillemets ou opérateurs
		mathématiques.
	</p>
	<p>
		De plus, un grand nombre de touches mortes et de caractères spéciaux présents dans le pilote
		d'Optimot ont été supprimés, ne conservant que l'essentiel. Cette simplification a permis de
		libérer de nombreux emplacements sur la couche <bkd>AltGr</bkd>. Les symboles, auparavant peu
		accessibles sur la rangée numérique, ont été déplacés pour être plus facilement atteints sous la
		couche <kbd>AltGr</kbd>, tandis que les chiffres sont désormais directement accessibles, un
		changement très appréciable lors de l'utilisation quotidienne.
	</p>
	<h3 data-aos="fade-right" data-aos-mirror="true">Évolution incrémentale</h3>
	<p>
		À un certain stade de développement, il devint évident que la disposition n'était plus
		simplement une variante d'Optimot. Le besoin de renommer ce projet s’est alors imposé. Grâce à
		la suggestion d’un utilisateur nommé Zigmund sur Discord, le nom <Nom></Nom> a été retenu, après
		avoir longtemps cherché une alternative aussi marquante que celui d’Optimot.
	</p>
	<p>
		Bien que la création de <Nom></Nom> ait été un processus étalé sur plusieurs mois, près de 80% de
		la disposition est restée constante. Les ajustements concernaient principalement le déplacement de
		certaines lettres, nécessitant ainsi des phases de réapprentissage régulières. Néanmoins, la plupart
		des changements se sont avérés non pertinents, ce qui explique l'absence de modifications majeures
		entre les premières versions d’Optim7 et la version finale de <Nom></Nom>.
	</p>

	<h3 data-aos="zoom-out" data-aos-mirror="true">Comment la disposition a été créée</h3>
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
	<petit-espace />
	<p>
		➁ La deuxième étape dans la création de la disposition a été de placer les touches les plus
		souvent utilisées le plus proche possible des doigts. Les doigts sont effectivement toujours
		censés reposer sur la rangée de repos du clavier (la ligne du milieu). Il est donc logique de
		chercher à placer sur cette rangée les lettres les plus utilisées pour réduire les déplacements
		des doigts aux touches.
	</p>
	<petit-espace />
	<p>
		➂ La troisième étape a été de déplacer les lettres pour réduire au maximum le nombre de <SFB
		/>s, tout en maximisant les roulements. Cette étape est la plus difficile, car intervertir
		seulement deux touches peut faire passer d’une disposition excellente à une disposition très
		moyenne. Il faut effectivement avoir en tête les bigrammes les plus fréquents et s’assurer que
		déplacer une touche à un autre emplacement ne va pas empirer la situation.
	</p>

	<h3 data-aos="fade-right" data-aos-mirror="true">
		Atouts de <NomPlus></NomPlus>
	</h3>
	<p>
		La singularité de <Nom></Nom> ne réside pas seulement dans ses excellents scores en français, anglais
		et en programmation, où elle rivalise avec les meilleures dispositions actuelles. Sa version étendue,
		<NomPlus></NomPlus>, pousse encore plus loin l’efficacité de cette disposition déjà très
		performante, en la rendant véritablement exceptionnelle. Le qualificatif d’exceptionnel n’est
		pas exagéré : <NomPlus></NomPlus> permet, une fois maîtrisée, de réduire presque totalement les <SFB
		></SFB>s, y compris ceux liés à la répétition d'une même touche. Cela est rendu possible grâce à
		la touche spéciale ★, permettant de réitérer la frappe de la touche précédente avec une fluidité
		inédite.
	</p>
	<p>
		Il convient de préciser que l’idée de cette touche de répétition n’est pas une invention propre,
		mais provient d'une disposition anglophone dont je ne retrouve plus le nom. D'autres éléments
		ont également été empruntés, comme l'utilisation d'AHK (AutoHotKey) dans la disposition Boo,
		pour modifier le comportement des combinaisons de touches. Ce système permet d'optimiser encore
		davantage les roulements sur les touches adjacentes qui n'engendrent pas de bigrammes habituels.
	</p>
</section>
