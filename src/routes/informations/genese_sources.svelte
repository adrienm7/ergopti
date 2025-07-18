<script>
	import Nom from '$lib/composants/Nom.svelte';
	import NomPlus from '$lib/composants/NomPlus.svelte';
	import SFB from '$lib/composants/SFB.svelte';
</script>

<h2>Genèse et inspirations</h2>
<p>
	La genèse de la disposition <Nom></Nom> remonte à début 2022, suite à la découverte de la disposition
	<a href="https://optimot.fr/">Optimot</a>. À ce moment-là, j’étais un utilisateur du
	<a href="https://bepo.fr/">BÉPO</a>
	depuis déjà de nombreuses années. Les améliorations d’Optimot par rapport au BÉPO sont significatives,
	avec notamment une forte diminution des bigrammes à un doigt (<SFB />s) et un meilleur placement
	des lettres pour l’anglais. Cependant, l'idée d'apprendre Optimot, pour peut-être découvrir encore
	par la suite une disposition encore meilleure, était peu attrayante.
</p>
<p>
	Pour m’assurer de ne pas avoir à passer mon temps à apprendre de nouvelles dispositions, toutes
	meilleures les unes que les autres, la solution a été radicale : développer la mienne, optimisée
	pour mes besoins. Évidemment, une telle tâche nécessite un investissement en temps considérable.
	Il faut déjà comprendre ce qui fait une bonne disposition, puis réarranger les touches pour en
	créer une au moins aussi bonne, si ce n’est meilleure, que les autres dispositions déjà
	disponibles. Enfin, il faut tester soi-même la disposition, car certains défauts n’apparaissent
	pas toujours sur un analyseur théorique. Et pour la tester, il faut réapprendre totalement à taper
	au clavier.
</p>

<mini-espace />

<p>
	Les premières versions de ce projet, baptisées <span class="important"
		><a href="https://bepo.fr/wiki/Utilisateur:Adrien_Moyaux">Optim7</a></span
	>, étaient des dérivés directs d'Optimot. L'objectif initial était de peaufiner légèrement les
	scores sur les analyseurs de disposition existants et de corriger des choix qui ne me convenaient
	pas. Par exemple, je voulais les chiffres en accès direct, ce qui n’est pas le cas en Optimot,
	l’auteur préférant y mettre les symboles.
</p>
<p>
	Rapidement, <Nom></Nom> s'éloigna d'Optimot sur plusieurs aspects fondamentaux. L'un des points clés
	était ma volonté d'optimiser les <i>roulements</i>, entraînant de nombreux tests de dispositions
	des touches de la homerow, notamment sur la partie droite avec les consonnes. Un des choix majeurs
	fut de privilégier un agencement <kbd>SNTR</kbd> plutôt que le
	<kbd>TSRN</kbd> du BÉPO et d’Optimot. En effet, le bigramme <kbd>NT</kbd> est le plus fréquent des
	bigrammes consonne-consonne, et il semblait pertinent de l'optimiser pour qu'il se réalise sur des
	doigts consécutifs. D’autant que <kbd>NTR</kbd> se réalise également en roulement.
</p>
<p>
	L’agencement final des quatre lettres de la rangée principale droite a été soigneusement conçu
	pour maximiser les bigrammes consonantiques, avec une disposition harmonieuse. Seuls les bigrammes <kbd
		>ST</kbd
	>
	et
	<kbd>TS</kbd> (comme dans « <kbd>ST</kbd>A<kbd>TS</kbd> ») ne profitent malheureusement pas de cette
	optimisation de roulements.
</p>
<p>
	La disposition a beaucoup évoluée au fil du temps. En particulier, la touche sur l’index gauche a
	plusieurs fois changé :
	<kbd>Q</kbd>, puis <kbd>P</kbd>, puis <kbd>W</kbd> et enfin la création d’une touche spéciale
	<kbd>★</kbd>
	et le déplacement de <kbd>É</kbd> sur l’annulaire gauche.
</p>
<p>
	Bien que la création de <Nom></Nom> ait été un processus étalé sur plusieurs années, près de 90% de
	la disposition est restée constante. Les ajustements concernaient principalement le déplacement de
	certaines lettres, nécessitant ainsi des phases de réapprentissage régulières. Néanmoins, la plupart
	des changements se sont avérés non pertinents, ce qui explique l'absence de modifications majeures
	entre les premières versions d’Optim7 et la version finale de <Nom></Nom>.
</p>

<mini-espace />

<p>
	À un certain stade de développement, il devint évident que ma disposition « Optim7 » n'était plus
	simplement une variante d'Optimot. Le besoin de renommer ce projet s’est alors imposé. Grâce à la
	suggestion d’un utilisateur nommé <strong>Zigmund</strong> sur Discord, après avoir longtemps
	cherché avec lui un nom aussi remarquablement bien trouvé que celui d’Optimot, le nom
	<span class="important">HyperTexte</span> fut d’abord retenu. Cependant, il s’avéra par la suite que
	ce nom était mal choisi, car déjà utilisé sur de nombreux sites ailleurs (ce qui n’est pas étonnant,
	cf. « lien hypertexte »). La découverte de la disposition, notamment grâce à un moteur de recherche,
	s'en trouvait compromise. Le site de présentation n’apparaissait même pas en première page des résultats.
</p>
<p>
	Environ un mois après la sortie publique de la disposition, HyperTexte fut renommée <Nom></Nom>,
	son nom final. Ce nouveau nom reflète à la fois l’ergonomie de la disposition et l’optimisation de
	celle-ci, la lettre <kbd>O</kbd> faisant le lien entre les deux (ergo[nomie] & opti[misation]). En
	outre, il est court, d’une longueur idéale de 7 lettres, et peu présent en ligne. Ce nouveau nom
	adopté, le nom de domaine <a href="https://ergopti.fr">https://ergopti.fr</a> fut également acquéri
	à ce moment-là.
</p>

<h3>Comment la disposition a été créée</h3>
<p>
	<i class="fa-duotone fa-circle-1"></i> La première étape dans la création d’<Nom /> a été de partager
	les touches du clavier en deux groupes : main gauche et main droite.
</p>
<p>
	Pour optimiser ce critère, les voyelles ont toutes été placées d’un côté du clavier. Celles-ci
	étant majoritairement précédées et suivies de consonnes, cela amène immédiatement une grande
	alternance des mains. À noter que cette idée est loin d’être nouvelle, car elle est déjà appliquée
	dans presque toutes les dispositions alternatives : Dvorak, BÉPO, Optimot, etc.
</p>
<p>
	Dans le cas d’<Nom />, les voyelles ont été placées sur le côté gauche. La raison est que sur la
	plupart des claviers standards il y a moins de touches sur ce côté. Le côté droit a en effet trois
	colonnes de touches pour l’auriculaire alors que l’auriculaire gauche n’en a qu’une. Ces nombreux
	emplacements sont précieux, surtout pour les langues ayant besoin de caractères supplémentaires,
	comme les accents en français. Le nombre de consonnes étant largement supérieur au nombre de
	voyelles, même en comptant les voyelles accentuées du français, les placer du côté avec le plus de
	touches était logique.
</p>

<mini-espace />

<p>
	<i class="fa-duotone fa-circle-2"></i> La deuxième étape dans la création de la disposition a été de
	placer les touches les plus souvent utilisées le plus proche possible des doigts. Les doigts sont effectivement
	toujours censés reposer sur la rangée de repos du clavier (la ligne du milieu). Il est donc logique
	de chercher à placer sur cette rangée les lettres les plus utilisées pour réduire les déplacements
	des doigts aux touches.
</p>

<mini-espace />

<p>
	<i class="fa-duotone fa-circle-3"></i> La troisième étape a été de déplacer les lettres pour
	réduire au maximum le nombre de <SFB />s, tout en maximisant les roulements. Cette étape est la
	plus difficile, car intervertir seulement deux touches peut faire passer d’une disposition
	excellente à une disposition très moyenne. Il faut effectivement avoir en tête les bigrammes les
	plus fréquents et s’assurer que déplacer une touche à un autre emplacement ne va pas empirer la
	situation.
</p>

<h3>
	Simplification et utilisation de la couche <kbd>AltGr</kbd>
</h3>
<p>
	<Nom /> utilise intensivement la couche <kbd>AltGr</kbd>. Celle-ci permet de réduire drastiquement
	les distances parcourues pour atteindre certaines touches. Un autre avantage est le fait que cette
	touche modificatrice est aisément atteignable par le pouce droit sur un clavier standard. Cela
	permet donc de mettre ce doigt à contribution, contrairement à l’AZERTY qui ne l’exploite pas
	suffisamment.
</p>
<p>
	N’ayant nullement besoin de tous les caractères exotiques et touches mortes du BÉPO ou d’Optimot,
	la majeure partie fut supprimée pour ne conserver que l’essentiel. Cette simplification permit de
	libérer de nombreux excellents emplacements sur la couche <kbd>AltGr</kbd> et me laissa assez de place
	pour y loger tous les symboles.
</p>
<p>
	Ainsi, plus besoin d’étendre les doigts pour atteindre la rangée des chiffres pour taper des
	parenthèses, guillemets ou opérateurs mathématiques. En outre, les chiffres sont quant à eux
	passés en accès direct, un changement très appréciable lors de l'utilisation quotidienne.
</p>

<h3>
	Atouts de <NomPlus></NomPlus>
</h3>
<p>
	La singularité de <Nom></Nom> ne réside pas seulement dans ses excellents scores en français, anglais
	et en programmation, où elle rivalise avec les meilleures dispositions actuelles. Sa version étendue,
	<NomPlus></NomPlus>, pousse encore plus loin l’efficacité de cette disposition déjà très
	performante, en la rendant véritablement exceptionnelle.
</p>
<p>
	Le qualificatif d’exceptionnel n’est pas exagéré : <NomPlus></NomPlus> permet, une fois maîtrisée,
	de réduire presque totalement les <SFB></SFB>s, y compris ceux liés à la répétition d'une même
	touche. Cela est rendu possible grâce à la touche spéciale <kbd>★</kbd>, permettant de réitérer la
	frappe de la touche précédente avec une fluidité inédite, ainsi qu’à la touche <kbd>,</kbd> de
	réduction des <SFB></SFB>s.
</p>
<p>
	Il convient de préciser que l’idée de cette touche de répétition n’est pas de mon invention. Elle
	provient d'une (voire plus) disposition anglophone dont je ne retrouve plus le nom. D'autres
	éléments ont également été empruntés, comme l'utilisation d'AHK (AutoHotKey) dans la disposition <a
		href="https://ballerboo.github.io/boolayout/">Boo</a
	>, pour modifier le comportement des combinaisons de touches. Ce système permet d'optimiser encore
	davantage les roulements sur les touches adjacentes qui n'engendrent pas de bigrammes habituels.
</p>
