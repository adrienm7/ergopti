# Audit de performance — Hammerspoon

Point d’entrée compatible pour un agent sans découverte automatique des skills.
Lis [`perf-profiling/SKILL.md`](../../.agents/skills/perf-profiling/SKILL.md), puis
[la référence Hammerspoon](../../.agents/skills/perf-profiling/references/hammerspoon.md).

Mesure le code actuel avant toute proposition. `doAfter(0)` reste sur la boucle
principale et les notifications de désactivation CoreGraphics ne sont pas
exposées comme événements Lua par le runtime Hammerspoon embarqué : ne réutilise
pas les anciennes hypothèses contredites par ces faits.

Écris le rapport sous
`docs/audits/performance/hammerspoon/<YYYY_MM_DD>/report.md` sans écraser une
passe existante. Cet audit ne modifie pas le driver et ne pousse rien.
