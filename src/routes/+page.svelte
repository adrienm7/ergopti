<script>
	import Nom from './Nom.svelte';
</script>

<h1>
	Disposition clavier<br />
	<span class="titre">
		<span class="titre-hyper">Hyper</span><span class="titre-texte">Texte</span>
	</span>
</h1>

<div style="height: 10vh;" />
<bloc-clavier id="bloc-clavier" />
<div style="height: 50px;" />

<p><Nom /> est une disposition clavier destinée à taper du français en de l’anglais.</p>

<h2>Disposition clavier optimale</h2>

<h3>Alternance des mains</h3>
<p>
	La première étape de la création d’<Nom /> a été d’essayer de classer les touches du clavier en deux
	groupes : main gauche et main droite. Pour cela, les voyelles ont toutes été placées du côté gauche,
	les voyelles étant majoritairement précédées et suivies de consonnes. Cette idée n’est pas nouvelle,
	elle est déjà appliquée dans presque toutes les dispositions alternatives : Dvorak, BÉPO, etc.
</p>
<h3>Distance des doigts aux touches</h3>
<p>
	La deuxième étape est de placer les touches les plus souvent utilisées sur la rangée de repos du
	clavier (la ligne du milieu).
</p>
<h3>Minimisation des SFB</h3>
