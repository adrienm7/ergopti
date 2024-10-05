<script>
	import Nom from '$lib/composants/Nom.svelte';
	import NomPlus from '$lib/composants/NomPlus.svelte';
	import SFB from '$lib/composants/SFB.svelte';

	import BlocClavier from '$lib/clavier/BlocClavier.svelte';
	import { Clavier } from '$lib/clavier/FonctionsClavier.js';
	let clavier = new Clavier('roulements');

	let texte;
	let roulements_voyelles = [
		'ai',
		'aie',
		'au',
		'eu',
		'ée',
		'ie',
		'ieu',
		'io',
		'oi',
		'ou',
		'ow',
		'wo',
		'you'
	];
	let roulements_consonnes = [
		'ch',
		'd’',
		'ld',
		'nc',
		'ng',
		'ns',
		'nt',
		'ntr',
		'pl',
		'pr',
		'rs',
		'tr',
		'th'
	];
</script>

<section>
	<h2 data-aos="zoom-out" data-aos-mirror="true">Optimisation des roulements</h2>
	<div class="content">
		<p>
			L’optimisation de l’alternance des mains engendre que lors de l’utilisation d’une main pour
			frapper une touche, il y a de fortes probabilités que le frappe suivante se produise avec
			l’autre main. Toutefois, cela n’arrive pas dans la totalité des cas, c’est pourquoi il
			convient de s’assurer que le plus possible de frappes intra-mains se fassent à l’aide de
			roulements, aussi appelés <i>rolls</i> en anglais.
		</p>
		<p>
			Ma définition personnelle d’un "roulement" est un déplacement sur deux doigts consécutifs et
			jamais à plus d’une rangée d’écart. Il y peu d’informations sur le sujet en ligne ; un
			roulement a probablement une définition plus large que la mienne, mais alors dans ce cas le
			côté "qui roule" est selon moi perdu. À la limite si c’est de l’index à l’auriculaire, mais
			pas de l’index à l’annulaire par exemple.
		</p>
		<p>
			En conclusion, un roulement est pour moi le <kbd>PO</kbd> de l’AZERTY ou le <kbd>ST</kbd> du
			BÉPO (idéalement, car mouvement horizontal). Sinon, c’est éventuellement le <kbd>PL</kbd> de
			l’AZERTY ou le <kbd>LS</kbd> du BÉPO. Toutefois, ce n’est pas le <kbd>ST</kbd> de l’AZERTY ni
			le <kbd>GL</kbd> du BÉPO.
		</p>
		<p>
			La disposition <Nom /> a été construite avec pour contrainte principale de permettre de réaliser
			les bigrammes consonne-consonne et voyelle-voyelle les plus courants grâce à des roulements, de
			préférence sur des doigts consécutifs dans un mouvement horizontal.
		</p>

		<h3 data-aos="fade-right" data-aos-mirror="true">Très bons bigrammes voyelle-voyelle</h3>
		<ul>
			<li><kbd>AI</kbd></li>
			<li><kbd>IE</kbd> et <kbd>EI</kbd></li>
			<li><kbd>EU</kbd></li>
			<li><kbd>IO</kbd> et <kbd>OI</kbd></li>
			<li><kbd>OU</kbd></li>
			<li><kbd>ÉE</kbd></li>
		</ul>

		Avec même quelques trigrammes très confortables :
		<ul>
			<li><kbd>AIE</kbd> notamment pour écrire <span class="hyper text-bold">AIE</span>NT</li>
			(avec en plus NT qui est lui aussi un roulement, que demander de plus ?)
			<li><kbd>IEU</kbd></li>
			<li><kbd>YOU</kbd></li>
		</ul>

		<h3 data-aos="fade-right" data-aos-mirror="true">Très bons bigrammes consonne-consonne</h3>
		<ul>
			<li><kbd>NS</kbd> et <kbd>SN</kbd></li>
			<li><kbd>NT</kbd></li>
			<li><kbd>TR</kbd> et <kbd>RT</kbd></li>
			<li><kbd>RS</kbd></li>
			<li>
				<kbd>CH</kbd> ce bigramme est extraordinaire, une fois habitué il est difficile de s’en passer
			</li>
			<li><kbd>PL</kbd></li>
			<li>
				<kbd>LD</kbd> surtout fréquent en anglais (O<span class="hyper text-bold">LD</span>, COU<span
					class="hyper text-bold">LD</span
				>, SHOU<span class="hyper text-bold">LD</span>, WOU<span class="hyper text-bold">LD</span>,
				etc.)
			</li>
			<li><kbd>D’</kbd></li>
			<li><kbd>NC</kbd></li>
			<li><kbd>NG</kbd> pour tous les -I<span class="hyper text-bold">NG</span> en anglais</li>
			<li><kbd>TH</kbd></li>
			<li><kbd>PR</kbd></li>
			<li><kbd>GR</kbd></li>
		</ul>
		<h3 data-aos="fade-right" data-aos-mirror="true">Autres bons bigrammes</h3>
		<ul>
			<li>
				<kbd>OW</kbd> très utilisé en anglais (ALL<span class="hyper text-bold">OW</span>, D<span
					class="hyper text-bold">OW</span
				>N, FOLL<span class="hyper text-bold">OW</span>, H<span class="hyper text-bold">OW</span>,
				KN<span class="hyper text-bold">OW</span>, N<span class="hyper text-bold">OW</span>,
				<span class="hyper text-bold">OW</span>N, SH<span class="hyper text-bold">OW</span>, etc.)
			</li>
			<li>
				<kbd>WO</kbd> très utilisé en anglais (T<span class="hyper text-bold">WO</span>,
				<span class="hyper text-bold">WO</span>MAN, <span class="hyper text-bold">WO</span>RD,
				<span class="hyper text-bold">WO</span>RK, <span class="hyper text-bold">WO</span>RLD,
				<span class="hyper text-bold">WO</span>RTH, <span class="hyper text-bold">WO</span>ULD,
				etc.)
			</li>
			<li><kbd>+=</kbd> utilisé en programmation pour incrémenter</li>
		</ul>

		<petit-espace />
		<p>Vous pouvez visualiser les roulements présentés précédemment ci-dessous :</p>
		<BlocClavier nom="roulements" />
		<div style="height: 20px" />
		<controles-roulements
			class="btn-group"
			style="width: 100%; margin: 0 auto; display: inline-block; text-align: center"
		>
			<select bind:value={texte} on:change={() => clavier.taperTexte(texte, 250, false)}>
				<option selected disabled hidden>Sélectionner le roulement</option>
				<option disabled>• Roulements voyelles •</option>
				{#each roulements_voyelles as value}<option {value}>{value.toUpperCase()}</option>{/each}
				<option disabled>• Roulements consonnes •</option>
				{#each roulements_consonnes as value}<option {value}>{value.toUpperCase()}</option>{/each}
			</select>
		</controles-roulements>
	</div>
</section>
