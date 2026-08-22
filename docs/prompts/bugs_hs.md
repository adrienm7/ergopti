# Audit adversarial — Hammerspoon

Ce fichier est un point d’entrée léger pour les agents sans découverte
automatique des skills. Lis, dans cet ordre,

1. [`adversarial-audit/SKILL.md`](../../.agents/skills/adversarial-audit/SKILL.md) ;
2. [la référence Hammerspoon](../../.agents/skills/adversarial-audit/references/hammerspoon.md) ;
3. [le contrat du rapport](../../.agents/skills/adversarial-audit/references/report-contract.md).

Exécute ensuite un audit Hammerspoon uniquement. Vérifie les faits contre le
code et les tests actuels : plusieurs défauts cités par d’anciens prompts ont
déjà été corrigés. Une hypothèse sans reproduction reste hors de
`findings.json`.

Produis le nouveau rapport sous
`docs/audits/hammerspoon/<YYYY_MM_DD>/{report.md,findings.json}`, puis valide le
manifeste avec `node tools/audit/workflow.cjs validate-report --report
<findings.json>`. N’écrase aucun rapport existant, n’implémente aucune correction
et ne pousse rien.
