# Keylogger spec — parité AHK ↔ Hammerspoon, sync multi-device, UI temps réel

Document de référence pour porter le keylogger Hammerspoon sur AutoHotkey
avec **parité byte-for-byte** des données persistées, permettre la
synchronisation entre plusieurs machines (mac + pc + autre mac…) avec
**diff-friendly Git out-of-the-box**, et garantir une **UI quasi-instantanée**
via du caching en base.

Toutes les références à des numéros de ligne renvoient à
`static/drivers/hammerspoon/modules/keylogger/{init,log_manager,context_tracker,kc_bridge}.lua`.

---

## 1. Disposition disque

### 1.1 Structure cible — un seul fichier source de vérité

Le **format sur disque** est exclusivement `data.sql`. SQLite reste
utilisé en interne pour les performances, mais son fichier `.sqlite`
vit dans le **tmpdir système** (`%TEMP%` Windows, `$TMPDIR` macOS), pas
dans le dossier metrics. C'est un cache transparent, pas un artefact
de configuration.

```
<config_dir>/metrics/                 ← dossier user-visible, syncable
  .gitignore                          ← écrit out-of-the-box (cf. §1.2)
  README.md                           ← idem, doc utilisateur
  by_device/
    <device_id>/
      device.json                     ← syncable, ~200 octets JSON
      data.sql                        ← syncable, source de vérité,
                                        append-only texte SQL
      today.log                       ← LOCAL only, JSONL hot-path

<tmpdir>/ergopti_metrics/             ← invisible utilisateur, jamais syncé
  <device_id>/
    db.sqlite                         ← cache interne, recréé à la demande
    db.sqlite-journal                 ← rollback journal de SQLite
```

**Conséquences directes** :

- Aucun script `.sh` / `.bat` à lancer pour rendre le format Git-friendly.
  Le format natif sur disque EST déjà du SQL texte.
- `.gitignore` minimal (`today.log` seulement) — plus de question
  « faut-il sync le binaire ».
- Dossier `metrics/` lisible : l'utilisateur voit `device.json` et
  `data.sql`, c'est tout.
- Si le tmpdir est wipé (reboot OS sur Windows / cleanup macOS), le
  cache se reconstruit transparentement au prochain boot du keylogger.

### 1.2 `.gitignore` shippé out-of-the-box

```gitignore
# Local hot-path log — never commit, never sync. One writer per device.
today.log
```

Ce fichier est créé par le keylogger lors de l'initialisation du dossier
`metrics/`. Si l'utilisateur le modifie, on respecte ses choix.

### 1.3 `<device_id>`

UUID v4 généré au premier démarrage du keylogger sur la machine,
persisté dans `device.json`. Le nom du dossier reproduit l'UUID
exactement (intégrité vérifiable).

### 1.4 `device.json`

```json
{
	"device_id": "f3c1a8e0-9b3d-4d2c-8a4f-2b6e1d9c0e3a",
	"name": "MBP-Adrien",
	"os": "darwin",
	"os_version": "14.5",
	"host_signature": "<IOPlatformUUID|MachineGuid>",
	"created_at": "2026-05-08 09:14:21.123",
	"schema_version": 1
}
```

Modifiable depuis l'UI (rename device). Mise à jour par le keylogger
à chaque évolution de schéma.

### 1.5 `today.log`

JSONL UTF-8 append-only. Une ligne = une entrée d’événement (cf. §3).
Sa seule raison d’exister est d’**absorber les écritures du hot path
clavier sans toucher à SQLite ni au .sql canonique**. Il est ingéré par
batch (cf. §15). Au day rollover, le fichier est draîné puis supprimé.

### 1.6 `data.sql`

Texte append-only, encoding UTF-8. Le keylogger n'y écrit que des
batches de `INSERT OR IGNORE` statements wrappés dans
`BEGIN TRANSACTION` / `COMMIT`. Aucune mise à jour, aucun DELETE — c'est
un journal append-only par construction.

Format détaillé en §15.5.

### 1.7 `db.sqlite` (cache tmpdir, jamais syncé)

Mode `journal_mode = DELETE`, `synchronous = FULL`. Single-writer (le
keylogger). Reconstruit depuis tous les `data.sql` (le local + ceux des
autres devices) au premier démarrage ou si le watermark interne est en
retard. Voir §15 pour le pipeline.

Chemin : `<tmpdir>/ergopti_metrics/<device_id>/db.sqlite`.

Le keylogger crée ce dossier au démarrage. Le sqlite cumule les données
de TOUS les devices (le local et les autres trouvés sous
`metrics/by_device/*/data.sql`). Du point de vue de l'UI, c'est une
base unique avec une colonne `device_id` partout.

---

## 2. Pipeline d’événement clavier

```
   keyDown / keyUp / flagsChanged / mouse event
                      │
                      ▼
   ┌──────────────────────────────────────┐
   │ Filtres en cascade (privacy/secure/   │
   │ system_auth/disabled_apps/silent_kc)  │
   └──────────────────────────────────────┘
                      │
                      ▼
   ┌──────────────────────────────────────┐
   │ Buffer / aggregate (cf. handle_key +  │
   │ flush_buffer côté HS, à porter en AHK)│
   └──────────────────────────────────────┘
                      │
                      ▼
   ┌──────────────────────────────────────┐
   │ append_log → today.log (JSONL)        │
   │ JAMAIS de write SQLite côté hot path. │
   └──────────────────────────────────────┘

                  …en parallèle (background tick)…

   ┌──────────────────────────────────────┐
   │ Ingest (§17)                          │
   │  - drain today.log → INSERT texte     │
   │  - APPEND aux batches de data.sql     │
   │  - APPLIQUE les mêmes INSERTs en      │
   │    transaction sur db.sqlite          │
   │  - UPSERT agg_app_day*, ngram_*       │
   │  - DELETE view_cache where today=1    │
   │  - PRE-WARM views (default today,     │
   │    last_7d, top10_apps…) → view_cache │
   └──────────────────────────────────────┘
```

---

## 3. Schéma des entrées du fichier `today.log`

JSONL, format identique à la version précédente du spec. Liste
exhaustive des `type` :

`typing` · `app_switch` · `window_switch` · `shortcut` · `system_event`
(action ∈ sleep/wake/lock/unlock/wifi_change/power_change/audio_change/
space_change/system_load) · `hotstring` · `hotstring_suggested` ·
`hotstring_dismissed` · `llm_generation` · `llm_suggested` ·
`llm_dismissed` · `llm_accepted` · `session_start` · `session_end` ·
`idle_start` · `idle_end`.

Les schémas par `type` sont inchangés vs HS d’origine — voir le code
HS et la première version du spec en historique Git si besoin.
**Le `device_id` n'apparaît PAS dans le JSONL** : il est implicite au
sous-dossier qui héberge `today.log`. Il est ajouté par l'ingest au
moment de générer les INSERT statements.

---

## 4. Constantes critiques (parité HS / AHK)

`MICRO_IDLE_TIMEOUT_MS=30000` · `SESSION_TIMEOUT_MS=300000` ·
`WPM_WINDOW_MS=15000` · `WPM_MIN_DURATION_MS=2000` ·
`IDLE_CHECK_INTERVAL_SEC=10` · `MAINTENANCE_INTERVAL_SEC=5` ·
`SYSTEM_LOAD_POLL_INTERVAL_MS=300000` · `SYNTH_MATCH_DELAY_MS=3` ·
`AUTO_FLUSH_IDLE_MS=120000` · `MAX_KEYSTROKE_DELAY_MS=5000` ·
`THINK_PAUSE_THRESHOLD_MS=2000` · `WPM_MAX_EVENT_DELAY_MS=5000` ·
`BURST_GAP_MS=1000` · `MIN_BURST_FOR_CPM=10` · `SESSION_GAP_MS=300000` ·
`BURST_LENGTH_BUCKETS={1,5,10,20,50,100,200,500}` ·
`AUTO_REPEAT_MAX_DELAY_MS=50` · `CASCADE_MIN_BS=3` · `HOLD_THRESHOLD_MS=250` ·
`UI_PAUSE_BUCKETS_MS={1000,2000,3000,5000,10000,20000,30000,60000}` ·
`SESSION_DURATIONS_CAP=100` · `TRIGGER_LOOKBACK_LEN=50` ·
`WIN_TITLES_CAP=100`.

Constantes ingest / cache :

| Nom                       | Valeur     | Sens                                                       |
| ------------------------- | ---------- | ---------------------------------------------------------- |
| `INGEST_TICK_MS`          | 5 000      | fréquence du tick d’ingest background.                     |
| `INGEST_FLUSH_THRESHOLD`  | 100        | nb lignes JSONL non-ingérées qui force un ingest immédiat. |
| `INGEST_BATCH_LINES`      | 5 000      | nb max de lignes par transaction (cap mémoire).            |
| `VIEW_CACHE_PREWARM_KEYS` | (cf. §18)  | liste des vues que l'on précompute après chaque ingest.    |
| `VIEW_CACHE_MAX_BYTES`    | 50 000 000 | budget total du cache en base ; LRU eviction si dépassé.   |

---

## 5. API publique du module keylogger

Inchangée. Modules externes appellent les mêmes fonctions :

```
M.start(script_control) / M.stop()
M.set_options / M.set_disabled_apps / M.set_*_filter_enabled
M.notify_synthetic(text, source_type, deletes, source_variant, deleted_text)
M.get_live_stats() → { wpm, wpm_physical, source, source_variant, source_time }
M.get_ngram_index() → vue read-only matérialisée à la volée depuis ngram_*
M.log_hotstring / log_hotstring_suggested / log_hotstring_dismissed
M.log_llm / log_llm_suggested / log_llm_dismissed / log_llm_accepted
M.log_shortcut
M.set_buffer (tests)
M.show_metrics
```

Plus une nouvelle fonction pour l'UI :

```
M.get_view(cache_key, params) → { data_json, computed_at }
  -- consulte view_cache puis recompute si miss.
M.list_devices() → [{device_id, name, os, …}]
  -- pour le filtre device dans l'UI.
```

---

## 6. Filtres de confidentialité

Inchangé : `private_filter_enabled`, `secure_field_filter_enabled`,
`system_auth_filter_enabled`, `disabled_apps`. Implémentations natives
HS et équivalents Windows à porter en séance 3.

---

## 7. Détection synthétique

Inchangé. `notify_synthetic()` doit être appelé AVANT le burst SendEvent.
Côté AHK : à câbler dans `HSE_DispatchMatch`.

---

## 8. Watchers et déclencheurs

Inchangé : tableau de correspondance HS ↔ Windows déjà documenté.

---

## 9. Différences de keycodes

Le keycode natif est dans `meta.kc` du JSONL (et dans la colonne
`events_json` après ingest). L'OS est dans `devices.os` — la heatmap UI
joint sur device_id pour router vers le mapping macOS ou Windows.

---

## 10. Différences fonctionnelles connues (gaps)

1. `space_change` : non émis côté Windows.
2. `AXDocument path` : peu d’apps Windows l'exposent → `null` la plupart du temps.
3. `IsPasswordPattern` UIA : v1 best-effort, accepter des faux-négatifs.
4. `bundleID` : remplacé par `process_name` côté Windows.
5. `kc_hold` côté Windows : timestamp via `KBDLLHOOKSTRUCT.time`.
6. Layout : noms `currentLayout()` ≠ `GetKeyboardLayoutName` — stockage
   tel quel, mapping cosmétique côté UI.

---

## 11. Plan d’architecture AHK

```
static/drivers/autohotkey/lib/keylogger/
  init.ahk           ; api publique
  event_loop.ahk     ; hook clavier/souris bas-niveau, pipeline filtres
  buffer.ahk         ; buffer_events / rich_chunks / synth_queue
  context_tracker.ahk; foreground app, window title, password field
  log_writer.ahk     ; append_log → today.log (UTF-8 JSONL)
  ingest.ahk         ; today.log → data.sql (texte) + db.sqlite (mirror)
  schema.ahk         ; chargement DDL et migrations depuis _shared/schema/
  watchers.ahk       ; WTS / power / wifi / audio / app focus
  sensors.ahk        ; mouse poll, system load, battery
  device_id.ahk      ; UUID + host_signature + fork-on-mismatch (§16)
  vk_to_finger.ahk   ; Windows VK → finger mapping
  view_cache.ahk     ; pre-warming + lookup pour l'UI
```

Lib SQLite côté AHK : `Class_SQLite.ahk` ou wrapper maison sur
`sqlite3.dll` via `DllCall` — à benchmarker en séance 3.

---

## 12. Plan d’architecture UI partagée

```
static/drivers/_shared/
  schema/
    schema.sql               ; DDL canonique de db.sqlite (§14)
    migrations/
      0001_initial.sql       ; schema_version = 1
  ui/
    metrics_apps/            ; HTML+CSS+JS uniquement
    metrics_typing/          ; idem
```

Côté HS, `ui/metrics_apps/init.lua` charge le HTML depuis `_shared/`.
Côté AHK (séance 4), launcher WebView2 charge la même page. Pas de
réécriture d’UI, juste un launcher différent par OS.

---

## 13. Décisions et questions encore ouvertes

### 13.1 Décisions actées

| #   | Sujet                                       | Décision                                                                                                                                                          |
| --- | ------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 1   | Lib SQLite côté AHK                         | `Class_SQLite.ahk` (mature, déjà éprouvée). Si bench montre un goulot, fallback wrapper maison sur `sqlite3.dll`.                                                 |
| 2   | Ingest tick                                 | 5 s par défaut, ajustable par constante `INGEST_TICK_MS`.                                                                                                         |
| 3   | Cap top-100 titres / 100 sessions durations | Validé.                                                                                                                                                           |
| 4   | Schema version                              | Démarre à 1, incrément à chaque breaking change.                                                                                                                  |
| 6   | Filtre password Windows                     | **Pas de best-effort** : séance dédiée pour faire le top — UIA `IsPasswordPattern` proprement combiné avec heuristiques control type / class names / app focused. |
| 8   | Migration depuis l'historique HS            | **Skip** — phase de tests, aucun utilisateur. On part vierge.                                                                                                     |
| 9   | Format Git diff-friendly                    | Le format natif sur disque EST déjà du SQL texte (`data.sql`). **Aucun script externe**, ni `.sh` ni `.bat`. Le `db.sqlite` vit dans tmpdir, jamais syncé.        |
| 10  | `device_info.name` éditable                 | Oui — modal « Renommer cet appareil » dans l'UI.                                                                                                                  |
| 11  | `view_cache` budget                         | 50 MB par défaut, ajustable (`VIEW_CACHE_MAX_BYTES`).                                                                                                             |
| 12  | Pré-warm post-ingest                        | `dashboard:today:default`, `dashboard:last_7d:default`, `top10_apps:today`, `hourly_heatmap:today`.                                                               |

### 13.2 À trancher au moment de l'implémentation correspondante

5. **Filtre private mode Windows** : à arbitrer en séance 3 quand on
   touchera au context_tracker AHK. Probable : keywords titre +
   détection InPrivate via UIA pour les browsers Chromium.
6. **Catégorisation app** : à arbitrer aussi en séance 3 — porter la
   table HS avec process names Windows (`code.exe`, `chrome.exe`, …).

---

## 14. Schéma SQLite — DDL canonique

Fichier de référence : `_shared/schema/schema.sql`. Bit-identique entre
les drivers (`schema_version` empêche les divergences).

```sql
-- ========== Méta + devices (registry cross-device) ==========

CREATE TABLE meta (
  key TEXT PRIMARY KEY,
  value TEXT NOT NULL
);
-- Clés gérées par le keylogger :
--   schema_version           → entier
--   last_applied_data_sql_off → entier (offset dans le data.sql LOCAL)
--   rev                       → entier auto-incrémenté à chaque ingest

CREATE TABLE devices (
  device_id TEXT PRIMARY KEY,
  name TEXT NOT NULL,
  os TEXT NOT NULL CHECK (os IN ('darwin','windows')),
  os_version TEXT,
  host_signature TEXT NOT NULL,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  -- Pour les autres devices, watermark de leur data.sql que l'on a déjà
  -- importé localement (en bytes). Rempli pour CE device aussi.
  imported_data_sql_size INTEGER NOT NULL DEFAULT 0,
  imported_data_sql_sha256 TEXT
);

-- ========== Événements bruts (toutes tables ont un device_id) ==========

CREATE TABLE events_typing (
  device_id TEXT NOT NULL,
  id INTEGER NOT NULL,                 -- per-device autoincrement (assigned at ingest)
  ts TEXT NOT NULL,
  date TEXT NOT NULL,
  app TEXT NOT NULL,
  title TEXT,
  url TEXT,
  field_role TEXT,
  layout TEXT,
  document_path TEXT,
  is_fullscreen INTEGER NOT NULL,
  in_meeting INTEGER NOT NULL,
  mouse_clicks INTEGER NOT NULL,
  mouse_scrolls INTEGER NOT NULL,
  mouse_distance_px INTEGER NOT NULL,
  pause_before_ms INTEGER,
  battery_level INTEGER,
  audio_volume REAL,
  wpm REAL,
  text TEXT NOT NULL,
  rich_text TEXT,
  events_json TEXT NOT NULL,
  PRIMARY KEY (device_id, id)
);
CREATE INDEX idx_events_typing_date_app ON events_typing(date, app);
CREATE INDEX idx_events_typing_device_date ON events_typing(device_id, date);

CREATE TABLE events_app_switch (
  device_id TEXT NOT NULL, id INTEGER NOT NULL,
  ts TEXT NOT NULL, date TEXT NOT NULL,
  prev_app TEXT, next_app TEXT,
  duration_ms INTEGER NOT NULL,
  PRIMARY KEY (device_id, id)
);
CREATE INDEX idx_events_app_switch_date ON events_app_switch(date);

CREATE TABLE events_window_switch (
  device_id TEXT NOT NULL, id INTEGER NOT NULL,
  ts TEXT NOT NULL, date TEXT NOT NULL,
  app TEXT NOT NULL,
  prev_title TEXT, next_title TEXT,
  duration_ms INTEGER NOT NULL,
  PRIMARY KEY (device_id, id)
);

CREATE TABLE events_shortcut (
  device_id TEXT NOT NULL, id INTEGER NOT NULL,
  ts TEXT NOT NULL, date TEXT NOT NULL,
  app TEXT NOT NULL, key TEXT NOT NULL,
  PRIMARY KEY (device_id, id)
);
CREATE INDEX idx_events_shortcut_date_app ON events_shortcut(date, app);

CREATE TABLE events_system (
  device_id TEXT NOT NULL, id INTEGER NOT NULL,
  ts TEXT NOT NULL, date TEXT NOT NULL,
  action TEXT NOT NULL,
  metadata_json TEXT,
  PRIMARY KEY (device_id, id)
);
CREATE INDEX idx_events_system_date_action ON events_system(date, action);

CREATE TABLE events_hotstring (
  device_id TEXT NOT NULL, id INTEGER NOT NULL,
  ts TEXT NOT NULL, date TEXT NOT NULL,
  app TEXT NOT NULL,
  kind TEXT NOT NULL CHECK (kind IN ('fired’,'suggested’,'dismissed’)),
  trigger TEXT NOT NULL,
  replacement TEXT NOT NULL,
  h_type TEXT,
  net_saved_chars INTEGER,
  PRIMARY KEY (device_id, id)
);
CREATE INDEX idx_events_hotstring_date_kind ON events_hotstring(date, kind);

CREATE TABLE events_llm (
  device_id TEXT NOT NULL, id INTEGER NOT NULL,
  ts TEXT NOT NULL, date TEXT NOT NULL,
  app TEXT NOT NULL,
  kind TEXT NOT NULL CHECK (kind IN ('generation','suggested’,'dismissed’,'accepted’)),
  context TEXT,
  predictions_json TEXT,
  prediction TEXT,
  all_predictions_json TEXT,
  chosen_index INTEGER,
  deletes INTEGER,
  deleted_text TEXT,
  net_saved_chars INTEGER,
  count INTEGER,
  PRIMARY KEY (device_id, id)
);

CREATE TABLE events_session (
  device_id TEXT NOT NULL, id INTEGER NOT NULL,
  ts TEXT NOT NULL, date TEXT NOT NULL,
  kind TEXT NOT NULL CHECK (kind IN ('session_start','session_end’,'idle_start','idle_end’)),
  duration_ms INTEGER,
  PRIMARY KEY (device_id, id)
);

-- ========== Agrégats précalculés (cœur du dashboard) ==========

-- Par day×app×device — somme par device en SUM() côté UI.
CREATE TABLE agg_app_day (
  device_id TEXT NOT NULL,
  date TEXT NOT NULL, app TEXT NOT NULL,
  chars INTEGER NOT NULL DEFAULT 0,
  pauses INTEGER NOT NULL DEFAULT 0,
  time_ms INTEGER NOT NULL DEFAULT 0,
  think_time_ms INTEGER NOT NULL DEFAULT 0,
  hs_chars INTEGER NOT NULL DEFAULT 0,
  llm_chars INTEGER NOT NULL DEFAULT 0,
  hs_triggers INTEGER NOT NULL DEFAULT 0,
  llm_triggers INTEGER NOT NULL DEFAULT 0,
  hs_suggested INTEGER NOT NULL DEFAULT 0,
  llm_suggested INTEGER NOT NULL DEFAULT 0,
  hs_input_chars INTEGER NOT NULL DEFAULT 0,
  llm_input_chars INTEGER NOT NULL DEFAULT 0,
  app_time_ms INTEGER NOT NULL DEFAULT 0,
  category TEXT,
  PRIMARY KEY (device_id, date, app)
);
CREATE INDEX idx_agg_app_day_date ON agg_app_day(date);

CREATE TABLE agg_app_day_buckets (
  device_id TEXT NOT NULL,
  date TEXT NOT NULL, app TEXT NOT NULL,
  bucket_ms INTEGER NOT NULL,
  time_sum INTEGER NOT NULL DEFAULT 0,
  credited INTEGER NOT NULL DEFAULT 0,
  hs_input_time_sum INTEGER NOT NULL DEFAULT 0,
  hs_input_credited INTEGER NOT NULL DEFAULT 0,
  llm_input_time_sum INTEGER NOT NULL DEFAULT 0,
  llm_input_credited INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY (device_id, date, app, bucket_ms)
);

CREATE TABLE agg_app_day_burst (
  device_id TEXT NOT NULL,
  date TEXT NOT NULL, app TEXT NOT NULL,
  count_total INTEGER NOT NULL DEFAULT 0,
  max_cpm REAL NOT NULL DEFAULT 0,
  max_chars INTEGER NOT NULL DEFAULT 0,
  length_buckets_json TEXT NOT NULL DEFAULT '{}',
  inter_delay_count INTEGER NOT NULL DEFAULT 0,
  inter_delay_sum INTEGER NOT NULL DEFAULT 0,
  inter_delay_sumsq INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY (device_id, date, app)
);

CREATE TABLE agg_app_day_session (
  device_id TEXT NOT NULL,
  date TEXT NOT NULL, app TEXT NOT NULL,
  count_total INTEGER NOT NULL DEFAULT 0,
  longest_ms INTEGER NOT NULL DEFAULT 0,
  longest_chars INTEGER NOT NULL DEFAULT 0,
  total_active_ms INTEGER NOT NULL DEFAULT 0,
  durations_json TEXT NOT NULL DEFAULT '[]',
  PRIMARY KEY (device_id, date, app)
);

CREATE TABLE agg_app_day_chars_class (
  device_id TEXT NOT NULL,
  date TEXT NOT NULL, app TEXT NOT NULL,
  letter INTEGER NOT NULL DEFAULT 0,
  digit INTEGER NOT NULL DEFAULT 0,
  punct INTEGER NOT NULL DEFAULT 0,
  space INTEGER NOT NULL DEFAULT 0,
  other INTEGER NOT NULL DEFAULT 0,
  first_typed_min TEXT,
  last_typed_min TEXT,
  PRIMARY KEY (device_id, date, app)
);

CREATE TABLE agg_app_day_errors (
  device_id TEXT NOT NULL,
  date TEXT NOT NULL, app TEXT NOT NULL,
  bs_total INTEGER NOT NULL DEFAULT 0,
  cascade_count INTEGER NOT NULL DEFAULT 0,
  cascade_max_len INTEGER NOT NULL DEFAULT 0,
  recovery_sum_ms INTEGER NOT NULL DEFAULT 0,
  recovery_count INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY (device_id, date, app)
);

CREATE TABLE agg_app_day_ergo (
  device_id TEXT NOT NULL,
  date TEXT NOT NULL, app TEXT NOT NULL,
  same_finger_streak_max INTEGER NOT NULL DEFAULT 0,
  same_hand_streak_max INTEGER NOT NULL DEFAULT 0,
  auto_repeat_count INTEGER NOT NULL DEFAULT 0,
  focus_to_first_key_sum_ms INTEGER NOT NULL DEFAULT 0,
  focus_to_first_key_count INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY (device_id, date, app)
);

CREATE TABLE agg_app_day_layouts (
  device_id TEXT NOT NULL,
  date TEXT NOT NULL, app TEXT NOT NULL,
  layout TEXT NOT NULL,
  count INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY (device_id, date, app, layout)
);

CREATE TABLE agg_app_day_kc_hold (
  device_id TEXT NOT NULL,
  date TEXT NOT NULL, app TEXT NOT NULL,
  keycode INTEGER NOT NULL,
  sum_ms INTEGER NOT NULL DEFAULT 0,
  count INTEGER NOT NULL DEFAULT 0,
  max_ms INTEGER NOT NULL DEFAULT 0,
  tap_count INTEGER NOT NULL DEFAULT 0,
  hold_count INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY (device_id, date, app, keycode)
);

CREATE TABLE agg_app_day_titles (
  device_id TEXT NOT NULL,
  date TEXT NOT NULL, app TEXT NOT NULL,
  title TEXT NOT NULL,
  c INTEGER NOT NULL DEFAULT 0,
  ms INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY (device_id, date, app, title)
);

CREATE TABLE agg_app_day_hourly (
  device_id TEXT NOT NULL,
  date TEXT NOT NULL, app TEXT NOT NULL,
  hour TEXT NOT NULL,                         -- "00".."23"
  c INTEGER NOT NULL DEFAULT 0,
  e INTEGER NOT NULL DEFAULT 0,
  em INTEGER NOT NULL DEFAULT 0,
  es INTEGER NOT NULL DEFAULT 0,
  e_buckets_json TEXT NOT NULL DEFAULT '{}',
  PRIMARY KEY (device_id, date, app, hour)
);

CREATE TABLE agg_app_day_hourly_min5 (
  device_id TEXT NOT NULL,
  date TEXT NOT NULL, app TEXT NOT NULL,
  slot TEXT NOT NULL,                         -- "HH:MM" pas de 5
  c INTEGER NOT NULL DEFAULT 0,
  e INTEGER NOT NULL DEFAULT 0,
  es INTEGER NOT NULL DEFAULT 0,
  e_buckets_json TEXT NOT NULL DEFAULT '{}',
  PRIMARY KEY (device_id, date, app, slot)
);

CREATE TABLE agg_app_day_switches_to (
  device_id TEXT NOT NULL,
  date TEXT NOT NULL,
  app_from TEXT NOT NULL,
  app_to TEXT NOT NULL,
  count INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY (device_id, date, app_from, app_to)
);

CREATE TABLE agg_system_day (
  device_id TEXT NOT NULL,
  date TEXT NOT NULL,
  wifi_changes INTEGER NOT NULL DEFAULT 0,
  space_switches INTEGER NOT NULL DEFAULT 0,
  battery_sum INTEGER, battery_count INTEGER,
  battery_min INTEGER, battery_max INTEGER,
  audio_muted_ms INTEGER NOT NULL DEFAULT 0,
  locked_ms INTEGER NOT NULL DEFAULT 0,
  sleep_ms INTEGER NOT NULL DEFAULT 0,
  awake_ms INTEGER NOT NULL DEFAULT 0,
  passive_count INTEGER NOT NULL DEFAULT 0,
  night_wake_count INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY (device_id, date)
);

-- ========== N-grammes (volume — séparés par taille) ==========

CREATE TABLE ngram_chars (
  device_id TEXT NOT NULL,
  date TEXT NOT NULL, app TEXT NOT NULL,
  token TEXT NOT NULL,
  c INTEGER NOT NULL DEFAULT 0,
  td INTEGER NOT NULL DEFAULT 0,
  cd INTEGER NOT NULL DEFAULT 0,
  e INTEGER NOT NULL DEFAULT 0,
  esrc_json TEXT NOT NULL DEFAULT '{}',
  PRIMARY KEY (device_id, date, app, token)
);
CREATE INDEX idx_ngram_chars_date_count ON ngram_chars(date, c DESC);

-- Tables identiques en schéma pour ngram_bigrams, ngram_trigrams,
-- ngram_quadgrams, ngram_pentagrams, ngram_hexagrams, ngram_heptagrams,
-- ngram_words, ngram_word_bigrams. Chaque table a son propre index
-- (date, c DESC) pour les top-N rapides.

CREATE TABLE ngram_shortcuts (
  device_id TEXT NOT NULL,
  date TEXT NOT NULL, app TEXT NOT NULL,
  token TEXT NOT NULL,
  c INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY (device_id, date, app, token)
);

CREATE TABLE ngram_shortcut_bigrams (
  device_id TEXT NOT NULL,
  date TEXT NOT NULL, app TEXT NOT NULL,
  token TEXT NOT NULL,
  c INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY (device_id, date, app, token)
);

CREATE TABLE ngram_keycodes (
  device_id TEXT NOT NULL,
  date TEXT NOT NULL, app TEXT NOT NULL,
  keycode INTEGER NOT NULL,
  c INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY (device_id, date, app, keycode)
);

-- ========== Cache de vues (UI temps réel — voir §18) ==========

CREATE TABLE view_cache (
  cache_key TEXT PRIMARY KEY,
  computed_at TEXT NOT NULL,
  data_json TEXT NOT NULL,
  depends_on_today INTEGER NOT NULL DEFAULT 0,
  size_bytes INTEGER NOT NULL,
  rev INTEGER NOT NULL                  -- meta.rev au moment du compute
);
CREATE INDEX idx_view_cache_today ON view_cache(depends_on_today);
CREATE INDEX idx_view_cache_size ON view_cache(size_bytes DESC);
```

---

## 15. Pipeline d’ingest — protocole crash-safe

### 15.1 Démarrage du keylogger

```
1. Lire device.json (config_dir/metrics/by_device/<device_id>/).
   Si absent : créer device_id (UUIDv4) + écrire device.json.
2. Comparer device.json.host_signature vs signature hardware actuelle.
   Mismatch → fork (cf. §16) : nouveau device_id, nouveau dossier.
3. Résoudre <tmpdir>/ergopti_metrics/<device_id>/.
4. Si tmpdir/db.sqlite absent OU meta.schema_version != current :
     créer db.sqlite (mode DELETE journal, synchronous=FULL),
     appliquer schema.sql + migrations,
     INSERT INTO devices (current device et tous les <id> trouvés
       sous metrics/by_device/*/ via leurs device.json).
     Replay TOUS les data.sql trouvés depuis le début → db.sqlite
       (premier boot ou cache wipé).
   Sinon :
     Pour CHAQUE <id> dans metrics/by_device/<id>/ :
       lire data.sql.size SZ.
       imported = devices[<id>].imported_data_sql_size.
       si SZ > imported :
         tail le fichier, appliquer les batches manquants,
         UPDATE devices SET imported_data_sql_size = SZ.
5. Si today.log existe (LOCAL device uniquement) :
     stat size, compare à last_today_log_offset (variable mémoire = 0).
     Ingest le fichier en entier.
     Si la première ligne date d’un autre jour (rollover loupé)
       → ingest puis DELETE.
6. Démarrer le hot path (today.log peut grossir à nouveau).
7. Programmer le tick d’ingest (INGEST_TICK_MS).
```

L'étape 4 est faite SYNC à l'init du keylogger pour que `db.sqlite` soit
complet avant l'ouverture de l'UI. Pour des fichiers énormes (plusieurs Go
de data.sql), peut prendre ~minutes au PREMIER boot ou si tmpdir a été
nettoyé ; les boots suivants sont incrémentaux et tiennent en <1 seconde.

### 15.2 Tick d’ingest

Pour chaque tick (5 s) OU dès que `INGEST_FLUSH_THRESHOLD` lignes
non-ingérées s'accumulent dans today.log :

```
1. Ouvrir today.log à l'offset last_today_log_offset.
2. Lire jusqu'à INGEST_BATCH_LINES lignes.
3. Pour chaque ligne JSON :
     parse → décider event_type → générer la (les) INSERT statement(s).
     accumuler dans un buffer texte (le batch SQL).
     accumuler dans le buffer programmatique (les params SQLite).
4. APPEND le batch texte à data.sql (entouré de
   "BEGIN TRANSACTION;\n…\nCOMMIT;\n").
   fsync data.sql.
5. BEGIN TRANSACTION sur db.sqlite.
   Exécuter les INSERTs + UPSERTs (events_*, agg_app_day*, ngram_*).
   UPDATE meta SET value = value+1 WHERE key='rev'.
   DELETE FROM view_cache WHERE depends_on_today = 1.
   UPDATE meta SET value = (current data.sql size) WHERE key='last_applied_data_sql_off'.
   COMMIT.
6. Pre-warm (cf. §18).
7. UPDATE last_today_log_offset (variable mémoire) à la position lue.
```

### 15.3 Day rollover

Détecté quand `os.date("%Y-%m-%d")` diverge de la date du dernier
batch ingéré.

```
1. Drainer la fin de today.log (ingest standard).
2. APPEND "-- === day rollover YYYY-MM-DD → YYYY-MM-DD ===\n" à data.sql.
3. DELETE today.log.
4. last_today_log_offset := 0.
5. Capping & maintenance :
   DELETE FROM agg_app_day_titles WHERE (device_id, date, app) IN
     (SELECT … LIMIT … OFFSET 100) — garder top-100.
   DELETE FROM view_cache WHERE depends_on_today = 1
     -- toutes les vues today deviennent obsolètes.
```

### 15.4 Garanties

- **Idempotence du replay** : `INSERT OR IGNORE` ; même si on rejoue un
  batch partiellement appliqué, les lignes existantes sont skippées.
- **Atomicité par batch** : `BEGIN/COMMIT` dans data.sql ET dans
  db.sqlite. Un tronquage à mi-batch dans data.sql ne casse rien : le
  `COMMIT;` final manquant signale un batch incomplet, ignoré au replay.
- **Crash mid-ingest** : `last_applied_data_sql_off` n'a pas avancé →
  on rejoue le batch au prochain tick → `INSERT OR IGNORE` neutralise
  les doublons.
- **Hot path jamais bloqué** : aucun write SQLite ni data.sql sur le
  thread du hook clavier.

### 15.5 Format texte canonique de `data.sql`

```sql
-- ergopti metrics — device <device_id> — schema_version 1
-- This file is APPEND-ONLY. Do not edit by hand.
-- The keylogger replays its content into db.sqlite at startup.
PRAGMA foreign_keys = OFF;

-- === ingest batch 2026-05-08 09:14:23.456 (lines 1..) ===
BEGIN TRANSACTION;
INSERT OR IGNORE INTO events_typing (device_id, id, ts, date, app, title, url, field_role, layout, document_path, is_fullscreen, in_meeting, mouse_clicks, mouse_scrolls, mouse_distance_px, pause_before_ms, battery_level, audio_volume, wpm, text, rich_text, events_json) VALUES ('abc-123-def-456', 1, '2026-05-08 09:14:21.123', '2026-05-08', 'Safari', 'GitHub', NULL, 'Unknown', 'Ergopti', NULL, 0, 0, 0, 0, 0, 4250, 78, 0.5, 92.5, 'hello', 'hello', '[["h",0,{"s":false,"st":"none","c":false,"ss":"right","r":"h","m":"","h":67,"d":0,"dk":false,"cp":false,"kc":4}]]');
INSERT OR IGNORE INTO agg_app_day (device_id, date, app, chars, time_ms, ...) VALUES ('abc-123-def-456', '2026-05-08', 'Safari', 5, 320, ...) ON CONFLICT(device_id, date, app) DO UPDATE SET chars = chars + excluded.chars, time_ms = time_ms + excluded.time_ms;
INSERT OR REPLACE INTO ngram_chars (device_id, date, app, token, c, td, cd, e, esrc_json) VALUES ('abc-123-def-456', '2026-05-08', 'Safari', 'h', 1, 0, 0, 0, '{}') ON CONFLICT(device_id, date, app, token) DO UPDATE SET c = c + 1;
COMMIT;

-- === ingest batch 2026-05-08 09:14:28.789 (lines 18..) ===
BEGIN TRANSACTION;
…
COMMIT;

-- === day rollover 2026-05-08 → 2026-05-09 ===

-- === ingest batch 2026-05-09 08:02:11.234 (lines 1..) ===
BEGIN TRANSACTION;
…
COMMIT;
```

Règles de format strictes :

- Une instruction SQL par ligne (pas de retour à la ligne au milieu d’un
  INSERT). Permet à un grep / blame / diff Git de cibler une frappe.
- Tous les strings sont single-quoted, échappement `'` → `''`.
- Tous les JSON embeddés (events_json, esrc_json…) sont serialisés sans
  retour à la ligne ni espacement décoratif (encoding compact).
- L'ordre des colonnes est figé par la version du schema.

---

## 16. Sync multi-device — protocole

### 16.1 Identité device

Inchangé. UUID v4 + host_signature ; fork-on-mismatch au démarrage.

### 16.2 Que est syncé / pas syncé

| Chemin                       | Syncé ? | Raison                                                  |
| ---------------------------- | ------- | ------------------------------------------------------- |
| `by_device/<id>/device.json` | OUI     | tiny, JSON, git-friendly.                               |
| `by_device/<id>/data.sql`    | OUI     | source de vérité, append-only texte.                    |
| `by_device/<id>/today.log`   | NON     | hot path local-only. Listé dans `.gitignore`.           |
| `metrics/.gitignore`         | OUI     | shipped out-of-the-box.                                 |
| `metrics/README.md`          | OUI     | doc utilisateur.                                        |
| `<tmpdir>/ergopti_metrics/…` | NON     | hors du dossier metrics, jamais syncé par construction. |

### 16.3 Comportements de sync

| Situation                                                                          | Conséquence                                                                                                                                                           |
| ---------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Device A appende un batch dans `data.sql`, sync engine copie le fichier mid-append | Le sync embarque jusqu'à où l'append est arrivé. Si le `COMMIT;` final manque, le batch incomplet est ignoré au replay (les lignes apparaîtront à la prochaine sync). |
| Device A et B typent en même temps offline                                         | Chacun écrit dans son propre `<device_id>/data.sql`. À la reconnection, sync transmet les deux fichiers, aucun conflit.                                               |
| Le user clone le dossier metrics d’un Mac vers un PC                               | Démarrage PC : host_signature mismatch → fork automatique. L'ancien `<id>/data.sql` reste comme « historique du Mac », le PC crée son propre `<new_id>/data.sql`.     |
| Le tmpdir du device est wipé (cleanup OS, reboot Windows en mode wipe-temp)        | Au prochain démarrage du keylogger, le sqlite est reconstruit depuis tous les `data.sql`. Coût : ~secondes pour une année de données.                                 |

### 16.4 Boot sur un device avec data.sql d’autres devices

```
foreach folder in by_device/*/:
  read folder/device.json
  if device_id not in devices table → INSERT
  read folder/data.sql.size SZ
  imported = devices[device_id].imported_data_sql_size
  if SZ > imported:
    tail folder/data.sql from offset `imported` to SZ
    apply each BEGIN..COMMIT batch in db.sqlite
    UPDATE devices SET imported_data_sql_size = SZ WHERE device_id = ?
```

Cette étape est faite SYNC à l'init du keylogger pour que `db.sqlite`
soit complet avant l'ouverture de l'UI. Pour des fichiers énormes
(plusieurs Go), peut prendre ~minutes au premier boot ; les boots
suivants sont incrémentaux.

---

## 17. (réservé)

---

## 18. Performance UI — caching strategy

### 18.1 Trois couches

**Couche 1 — agrégats permanents (`agg_*` tables)**.
Mises à jour à chaque ingest batch via UPSERT. La majorité des vues
dashboard (today, last 7d, top apps, hourly heatmap) tapent uniquement
ces tables : 1 SELECT, ~50-500 rows, <5 ms.

**Couche 2 — `view_cache` (rendu pré-projeté en JSON)**.
Pour les vues coûteuses (n-grammes top-100 sur 90 jours, sankey
typing-paths multi-devices, bursts records cross-period). Stocke le
JSON déjà projeté → l'UI n'a qu'à le `JSON.parse` + render.

Schéma rappel (cf. §14) :

```sql
view_cache (cache_key, computed_at, data_json, depends_on_today,
            size_bytes, rev)
```

**Cache key** = hash stable de `(view_id, period_start, period_end,
app_filter, device_filter, threshold, schema_version)`. Format
recommandé : `sha256(JSON.stringify(canonicalized_params))[0:16]`.
Détection du `depends_on_today` = `period_end >= today's date`.

Lookup logic (côté Lua / AHK) :

```
function get_view(cache_key, compute_fn):
  row = SELECT * FROM view_cache WHERE cache_key = ?
  if row and row.rev == meta.rev:
    return row.data_json
  data = compute_fn()  -- fait les SELECTs nécessaires sur agg_* / ngram_*
  INSERT OR REPLACE INTO view_cache (cache_key, computed_at, data_json,
    depends_on_today, size_bytes, rev) VALUES (?, now, ?, ?, ?, meta.rev)
  enforce_budget()  -- LRU eviction si SUM(size_bytes) > VIEW_CACHE_MAX_BYTES
  return data
```

Invalidation par ingest batch :

```sql
DELETE FROM view_cache WHERE depends_on_today = 1;
```

→ Les vues historiques cachent à vie. Day rollover → DELETE all (le jour
d’hier devient « today historique » mais on préfère recompute pour les
filtres « rolling 7 days » qui le touchent).

LRU budget `VIEW_CACHE_MAX_BYTES` (50 MB par défaut) :

```sql
WITH ordered AS (
  SELECT cache_key FROM view_cache
  ORDER BY computed_at ASC
)
DELETE FROM view_cache
WHERE cache_key IN (
  SELECT cache_key FROM ordered
  WHERE size_bytes_running_sum > VIEW_CACHE_MAX_BYTES
);
```

**Couche 3 — pré-warming background**.
Après chaque ingest batch (`§15.2 step 6`), le keylogger lance en async
le calcul des vues les plus fréquentes :

```
VIEW_CACHE_PREWARM_KEYS = [
  ("dashboard", "today",   "default", "any_device"),
  ("dashboard", "last_7d", "default", "any_device"),
  ("top_apps",  "today",   "n=10",    "any_device"),
  ("hourly_heatmap", "today", "any_app", "any_device"),
]
```

Quand l'utilisateur ouvre le dashboard 30 secondes plus tard, ces vues
sont déjà dans `view_cache` → first paint <1 ms.

### 18.2 Indexes critiques pour les requêtes hot

Au-delà des PK :

```sql
-- Range scans sur dates (UI sélectionne des périodes)
CREATE INDEX idx_agg_app_day_date     ON agg_app_day(date);
CREATE INDEX idx_agg_app_day_app      ON agg_app_day(app);
CREATE INDEX idx_events_typing_date   ON events_typing(date);

-- Top-N n-grammes sur date / app (covering pour ORDER BY c DESC LIMIT)
CREATE INDEX idx_ngram_chars_date_count        ON ngram_chars(date, c DESC);
CREATE INDEX idx_ngram_bigrams_date_count      ON ngram_bigrams(date, c DESC);
CREATE INDEX idx_ngram_trigrams_date_count     ON ngram_trigrams(date, c DESC);
CREATE INDEX idx_ngram_quadgrams_date_count    ON ngram_quadgrams(date, c DESC);
CREATE INDEX idx_ngram_pentagrams_date_count   ON ngram_pentagrams(date, c DESC);
CREATE INDEX idx_ngram_hexagrams_date_count    ON ngram_hexagrams(date, c DESC);
CREATE INDEX idx_ngram_heptagrams_date_count   ON ngram_heptagrams(date, c DESC);
CREATE INDEX idx_ngram_words_date_count        ON ngram_words(date, c DESC);
CREATE INDEX idx_ngram_word_bigrams_date_count ON ngram_word_bigrams(date, c DESC);
CREATE INDEX idx_ngram_shortcuts_date_count    ON ngram_shortcuts(date, c DESC);

-- Heatmap des keycodes
CREATE INDEX idx_ngram_keycodes_date_count     ON ngram_keycodes(date, c DESC);
CREATE INDEX idx_agg_app_day_kc_hold_keycode   ON agg_app_day_kc_hold(keycode);
```

### 18.3 Estimation des temps de réponse

| Action utilisateur                                   | Path                              | Temps perçu           |
| ---------------------------------------------------- | --------------------------------- | --------------------- |
| Ouvrir le dashboard pour la 1re fois aujourd’hui     | view_cache hit (pré-warmé)        | ~5 ms first paint     |
| Ouvrir le dashboard 30 min plus tard sans avoir tapé | view_cache hit (`rev` inchangé)   | <1 ms                 |
| Ouvrir 30 min plus tard après ~50 frappes            | view_cache miss → recompute       | ~20 ms                |
| Switch « aujourd’hui » → « cette semaine »           | view_cache hit (vue persistante)  | <1 ms                 |
| Switch app filter                                    | view_cache miss → recompute       | ~20-50 ms             |
| Switch threshold de pause                            | agg_app_day_buckets direct SELECT | <5 ms                 |
| Vue n-grams top-100 sur 90 jours                     | view_cache miss → SELECT + LIMIT  | ~50-150 ms puis <1 ms |
| Live update (nouveau keystroke)                      | dashboard reçoit push             | <5 ms                 |

### 18.4 Live updates (push depuis le keylogger)

Le keylogger maintient une liste des dashboards ouverts (via leur
webview). Après chaque ingest batch + pré-warm :

```
foreach open_webview:
  webview.executeScript("window.metrics_on_data_update(<rev>)")
```

Le JS regarde son `last_seen_rev` :

```js
window.metrics_on_data_update = (rev) => {
	if (rev === window.last_seen_rev) return;
	refresh_dashboard_view(); // appelle get_view(...)
	window.last_seen_rev = rev;
};
```

Pas de polling. Pas de WebSocket. Juste un `executeScript` opportuniste
quand le keylogger sait que le `rev` a bougé. Coût zéro côté UI tant que
l'utilisateur ne tape pas.

### 18.5 Budget mémoire / disque

- `view_cache` cap : 50 MB total. LRU eviction. Pour référence :
  un JSON de dashboard top-100 bigrams sur 1 an pèse <100 KB → 500
  vues différentes peuvent cohabiter avant éviction.
- `db.sqlite` croissance : ~5-10 MB / mois pour un user typique
  (typing data tables compresseraient bien mais SQLite ne compresse pas
  par défaut — VACUUM nightly suffit).
- `data.sql` : ~même volume que db.sqlite mais en texte (plus gros,
  ~2-3×). Compresse comme un texte (Git pack files efficaces, ratio
  > 5:1).

---

## 19. Migration des données HS existantes

**Skip — phase de tests, aucun utilisateur en prod.** À l'activation du
nouveau keylogger, on part vierge : le keylogger crée un nouveau dossier
`metrics/by_device/<new_uuid>/`, écrit un nouveau `data.sql` vide, et
n'importe rien des éventuels anciens `*.log` / `manifest.json` qui
traînaient.

L'utilisateur peut supprimer manuellement l'ancien dossier metrics
avant le premier démarrage s'il veut une mise au propre absolue.

---

## Récapitulatif des fichiers à produire

Séance 2 (extraction UI partagée + branchement HS) :

- `static/drivers/_shared/schema/schema.sql` — DDL canonique.
- `static/drivers/_shared/schema/migrations/0001_initial.sql`.
- `static/drivers/_shared/ui/metrics_apps/{index.html,script.js,style.css,README.md}`.
- `static/drivers/_shared/ui/metrics_typing/{index.html,*.js,style.css,README.md}`.
- `static/drivers/_shared/scripts/data_sql_parser.lua` — utilitaire
  partagé pour parser les batches data.sql (utilisé par le replay HS,
  servira aussi côté AHK).
- Mise à jour de `static/drivers/hammerspoon/modules/keylogger/log_manager.lua`
  pour écrire `today.log` (JSONL) + `data.sql` (texte append-only) +
  `db.sqlite` dans tmpdir, au lieu de .log + .idx + manifest.json.
- Mise à jour de `static/drivers/hammerspoon/ui/metrics_*/init.lua`
  pour pointer vers `_shared/ui/`.

Séance 3 (port AHK keylogger) :

- Tout sous `static/drivers/autohotkey/lib/keylogger/` (cf. §11).
- Tests unitaires AHK qui valident la parité byte-pour-byte de `data.sql`
  généré par AHK vs HS pour des inputs identiques (modulo timestamps et
  device_id).

Séance dédiée (priorité haute, après séance 4) :

- Filtre password Windows robuste : UIA `IsPasswordPattern` proprement
  combiné avec heuristiques control type / class names / app focused.
  Pas de best-effort — séance entière pour faire le top.

Séance 4 (UI launcher AHK) :

- `static/drivers/autohotkey/lib/metrics_ui/webview2_launcher.ahk`.
- Branchement menu tray.
