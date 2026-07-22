<!-- src/routes/ergopti-plus/StickyCta.svelte -->

<!--
==============================================================================
MODULE: Ergopti+ Page — Sticky Download CTA
DESCRIPTION:
A discreet download pill that slides in once the visitor has scrolled past the
hero and hides again as the real download section comes into view, so it never
competes with the final call-to-action. OS-aware, like the hero button.
==============================================================================
-->

<script>
	import { onMount } from 'svelte';
	import { ui } from './state.svelte.js';

	// Same OS → asset mapping as the hero's primary button.
	let url = $derived(
		ui.osStyle === 'macos'
			? (ui.release?.url('ErgoptiPlus.app.zip') ?? '#')
			: ui.osStyle === 'linux'
				? (ui.release?.url('kanata.kbd') ?? '#')
				: (ui.release?.url('ErgoptiPlus.exe') ?? '#')
	);
	let label = $derived(
		ui.osStyle === 'macos' ? 'macOS' : ui.osStyle === 'linux' ? 'Linux' : 'Windows'
	);
	let icon = $derived(
		ui.osStyle === 'macos'
			? 'icon-appleinc'
			: ui.osStyle === 'linux'
				? 'icon-linux'
				: 'icon-windows'
	);

	let visible = $state(false);

	onMount(() => {
		const finalCta = document.getElementById('ep-telecharger');
		let ticking = false;
		const onScroll = () => {
			if (ticking) return;
			ticking = true;
			requestAnimationFrame(() => {
				const pastHero = window.scrollY > window.innerHeight * 0.9;
				// Fade out once the real download section is nearly in view.
				let nearFinal = false;
				if (finalCta) {
					nearFinal = finalCta.getBoundingClientRect().top < window.innerHeight * 0.9;
				}
				visible = pastHero && !nearFinal;
				ticking = false;
			});
		};
		window.addEventListener('scroll', onScroll, { passive: true });
		onScroll();
		return () => window.removeEventListener('scroll', onScroll);
	});
</script>

<a class="sticky-cta" class:visible href={url} download={!!ui.release}>
	<i class={icon}></i>
	<span>Télécharger — {label}</span>
</a>

<style>
	.sticky-cta {
		align-items: center;
		background: linear-gradient(135deg, var(--accent-blue-deep, #1f6feb), var(--accent-cyan, #02c9db));
		border-radius: 999px;
		bottom: 22px;
		box-shadow: 0 12px 34px -10px rgba(2, 201, 219, 0.7);
		color: #fff;
		display: inline-flex;
		font-size: 0.9rem;
		font-weight: 700;
		gap: 8px;
		left: 50%;
		opacity: 0;
		padding: 11px 20px;
		pointer-events: none;
		position: fixed;
		text-decoration: none;
		transform: translate(-50%, 20px);
		transition:
			opacity 0.3s var(--ease, ease),
			transform 0.3s var(--ease, ease);
		z-index: 80;
	}

	.sticky-cta.visible {
		opacity: 1;
		pointer-events: auto;
		transform: translate(-50%, 0);
	}

	@media (prefers-reduced-motion: reduce) {
		.sticky-cta {
			transition: opacity 0.3s ease;
		}

		.sticky-cta.visible {
			transform: translate(-50%, 0);
		}
	}
</style>
