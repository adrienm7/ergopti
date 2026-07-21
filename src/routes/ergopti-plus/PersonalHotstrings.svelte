<!-- src/routes/ergopti-plus/PersonalHotstrings.svelte -->

<!--
==============================================================================
MODULE: Ergopti+ Page — Personal & Dynamic Hotstrings
DESCRIPTION:
The "your own shortcuts" story: TOML-backed personal hotstrings added in one
click from the menu, and @-prefixed dynamic hotstrings computed at fire time
(dates, personal info).

FEATURES & RATIONALE:
1. Sales Angle: the shipped catalog is the base; what converts users is
   adding THEIR signature/IBAN in 5 seconds without touching code.
==============================================================================
-->

<script>
	import DriverFrame from './DriverFrame.svelte';
	import { reveal } from './reveal.js';

	/** @type {{geo: Record<string, {width: number, height: number}>}} */
	let { geo } = $props();

	// Live personal info — seeded with the demo values shown in the embedded
	// window, then UPDATED IN REAL TIME as the visitor edits the real
	// personal-info window below. Every example on this screen derives from
	// these fields, which is exactly how the driver's dynamic hotstrings work.
	let info = $state({
		first_name: 'Adrien',
		last_name: 'Moyaux',
		email: 'adrien@exemple.fr',
		phone: '+33 6 12 34 56 78',
		address: '15 rue Lafayette, 75009 Paris',
		iban: 'FR76 1234 5678 9012 3456 789'
	});

	/**
	 * Receive live edits from the embedded personal-info window.
	 * @param {Record<string, string>} fields
	 */
	function onInfoChange(fields) {
		info = { ...info, ...fields };
	}

	const today = new Date();
	const dateShort = today.toLocaleDateString('fr-FR');
	const dateLong = today.toLocaleDateString('fr-FR', {
		day: 'numeric',
		month: 'long',
		year: 'numeric'
	});

	let personalExamples = $derived([
		{
			trig: 'np★',
			out: `${info.first_name} ${info.last_name}`.trim() || '…',
			desc: 'Nom complet'
		},
		{ trig: 'em★', out: info.email || '…', desc: 'E-mail' },
		{ trig: 'tel★', out: info.phone || '…', desc: 'Téléphone' },
		{ trig: 'sig★', out: `Cordialement, ${info.first_name}`.trim(), desc: 'Signature' },
		{ trig: 'ad★', out: info.address || '…', desc: 'Adresse' },
		{ trig: 'iban★', out: info.iban || '…', desc: 'IBAN' }
	]);

	let dynamicExamples = $derived([
		{ trig: '@dt', out: dateShort, desc: 'Date du jour' },
		{ trig: '@dtL', out: dateLong, desc: 'Date en lettres' },
		{ trig: '@ph', out: info.phone || '…', desc: 'Téléphone configuré' },
		{
			trig: '@np★',
			out: `${info.last_name} ⇥ ${info.first_name}`.trim(),
			desc: 'Remplissage de formulaire'
		}
	]);

	const steps = [
		'Sélectionnez un texte que vous tapez souvent.',
		'Ouvrez le menu → Hotstrings personnels.',
		'Choisissez un déclencheur (ex : sig★).',
		'C’est actif — sans redémarrer le driver.'
	];
</script>

<section class="personal" id="perso-hotstrings" style="--section-accent: #8e8e93;">
	<div class="ep-wrap">
		<header class="section-head" use:reveal>
			<p class="kicker">Vos propres raccourcis</p>
			<h2>Et ceux que <em>vous</em> tapez tous les jours.</h2>
			<p class="lead">
				Signature, IBAN, formules récurrentes : ajoutez vos hotstrings <strong>en un clic</strong>
				depuis le menu — stockés dans un simple fichier TOML, rechargés à la volée.
			</p>
		</header>

		<div class="personal-grid">
			<article class="ep-card" use:reveal>
				<h3>Ajout en 5 secondes</h3>
				<ol class="steps">
					{#each steps as s, i}
						<li><span class="step-num">{i + 1}</span><span>{s}</span></li>
					{/each}
				</ol>
				<ul class="rows">
					{#each personalExamples as p}
						<li>
							<span class="hs-key">{p.trig}</span>
							<span class="hs-arrow">→</span>
							<span class="hs-out">{p.out}</span>
							<span class="hs-desc">{p.desc}</span>
						</li>
					{/each}
				</ul>
			</article>

			<article class="ep-card" use:reveal={{ delay: 90 }}>
				<h3>Hotstrings dynamiques</h3>
				<p class="card-lead">
					Certaines valeurs changent tous les jours (la date) ou ne doivent pas être écrites en dur
					(téléphone, IBAN). Le préfixe <code>@</code> les calcule <strong>au moment précis</strong>
					du déclenchement, depuis l’éditeur d’informations personnelles.
				</p>
				<ul class="rows">
					{#each dynamicExamples as d}
						<li>
							<span class="hs-key">{d.trig}</span>
							<span class="hs-arrow">→</span>
							<span class="hs-out">{d.out}</span>
							<span class="hs-desc">{d.desc}</span>
						</li>
					{/each}
				</ul>
				<p class="card-foot">
					Nom, e-mail, téléphone, adresse, IBAN : tout est centralisé dans une seule fenêtre — les
					hotstrings dynamiques s’en servent automatiquement.
				</p>
			</article>
		</div>

		<!-- The REAL personal-info window, live-wired to the examples above -->
		<div class="info-embed">
			<p class="info-lead" use:reveal>
				La fenêtre en question — la vraie. <strong>Modifiez un champ ci-dessous</strong> : les
				exemples <code>np★</code>, <code>sig★</code>, <code>@np★</code>… au-dessus se réécrivent en
				direct, exactement comme le feront vos expansions.
			</p>
			<DriverFrame
				id="personal_info_editor"
				width={geo.personal_info_editor?.width ?? 560}
				height={geo.personal_info_editor?.height ?? 680}
				displayHeight={480}
				oninfochange={onInfoChange}
			/>
		</div>
	</div>
</section>

<style>
	.personal-grid {
		display: grid;
		gap: 16px;
		grid-template-columns: repeat(2, 1fr);
	}

	.steps {
		display: flex;
		flex-direction: column;
		gap: 9px;
		list-style: none;
		margin: 0 0 18px;
	}

	.steps li {
		align-items: baseline;
		color: var(--ink-soft);
		display: flex;
		font-size: 0.92rem;
		gap: 10px;
	}

	.step-num {
		align-items: center;
		background: rgba(49, 190, 255, 0.12);
		border: 1px solid rgba(49, 190, 255, 0.3);
		border-radius: 50%;
		color: var(--accent-blue);
		display: inline-flex;
		flex-shrink: 0;
		font-size: 0.72rem;
		font-weight: 800;
		height: 22px;
		justify-content: center;
		position: relative;
		top: 2px;
		width: 22px;
	}

	.rows {
		display: flex;
		flex-direction: column;
		gap: 9px;
		list-style: none;
	}

	.rows li {
		align-items: baseline;
		display: flex;
		flex-wrap: wrap;
		gap: 6px 10px;
	}

	.rows .hs-desc {
		margin-left: auto;
	}

	.card-lead {
		margin-bottom: 16px;
	}

	.card-foot {
		border-top: 1px solid var(--border);
		color: var(--ink-faint);
		font-size: 0.85rem;
		margin-top: 16px;
		padding-top: 14px;
	}

	@media (max-width: 880px) {
		.personal-grid {
			grid-template-columns: 1fr;
		}
	}

	.info-embed {
		margin-top: clamp(24px, 3.5vw, 36px);
	}

	.info-lead {
		color: var(--ink-soft);
		font-size: 0.92rem;
		margin: 0 0 16px;
		text-align: center;
	}
</style>
