# Windows secret storage and encryption flow audit

Audited SHA: `213d65af24d2aa4845ba47743c9bab6787b61964`.
Scope: Windows metrics typed-text encryption/decryption and migration, API/proxy
credential persistence and use, and native crypto/key ownership. Production and
registered tests were read-only. This is one OS/module flow audit, with narrow
macOS/Linux comparisons. Paths below are relative to `static/ergopti_plus/`.

## Result and evidence boundary

One new root cause is confirmed from the complete current Windows source path:
raw typing text beginning with the ciphertext marker is accepted as already
protected and persisted literally into the protected SQL text column. macOS/Linux
have the same shared-policy root, independently exercised by their real cipher
and SQL owners; they should be integrated as **one cross-driver issue**.

Windows additionally interprets a malformed marker-prefixed literal as an invalid
envelope on decrypt, and cannot finish the decrypt migration over it. A genuine-
owner Windows AHK reproducer is supplied but **not executed**: this host has no
AutoHotkey/Wine, CNG or DPAPI. The Windows branch/ingress findings are source-backed;
no claim of native menu/input/disk behavior was made. Comparator artifacts were
opened and inspected directly, not accepted solely from another agent's summary.

WM-002 / AHK-005 (durable raw today.log despite the encryption option) is already
reported and explicitly excluded from new findings. The present defect bypasses
the **SQL column encryption itself**, even if the journal issue is fixed.

### WCR-001 — Cipher marker in legitimate raw typing bypasses SQL encryption

Severity: medium. Confidence: high (deterministic Windows source path plus
executed sibling policy/SQL evidence; native Windows reproduction unavailable).
Guarantees: none of G1–G5 is used as a surrogate confidentiality guarantee.
Additional property: confidentiality of the literal typed-text SQL column under
enabled at-rest encryption, and lossless separation of raw input from a stored
envelope. The decrypt/migration consequence is recorded without claiming a silent
whole-dashboard data loss or applying G2 to a loudly reported migration failure.

Concrete flow:

1. Enable the Metrics encryption option and let any existing migration settle.
   In a permitted editor whose typing is recorded, type or paste an ordinary
   synthetic sentence starting `ergopti-enc-v1:SENTINEL-PRIVATE-CONTENT`, then cause
   the normal typing snapshot to flush. No crafted database corruption is needed.
2. `windows/modules/keystats/keystats_sql.ahk:64` reads the actual raw event `text`;
   `KL_BuildInsertTyping:68` passes it directly to `KL_Enc_Encrypt`.
3. `windows/modules/keystats/keystats_text_cipher.ahk:214` handles this as a raw
   encryption call. Before key/native work, `:220` calls `KL_Enc_IsEncrypted`;
   that predicate at `:169` tests only the `ergopti-enc-v1:` prefix. The early
   return emits the original raw text without invoking AES.
4. The SQL builder only rejects an empty result for nonempty input. This nonempty
   returned literal therefore becomes `Slots["text"]` at `keystats_sql.ahk:85`
   and is quoted by the genuine `events.typing` query renderer. JSON key events
   still get their separate encryption call; only the text branch was bypassed.
5. Encryption migration (`keystats_text_migration.ahk:428`) uses the same prefix
   predicate, skips the literal as already wrapped, and can report an unchanged
   successful conversion for it. Decrypt migration treats the literal as wrapped;
   `KL_Enc_Decrypt:250` finds no IV/payload separator and returns empty, so the
   conversion refuses at migration `:446`. The pass aborts without replacing the
   original ledger, as designed. The bad representation survives; no original
   ledger destruction is asserted.

A second control must be a literal string that happens to look exactly like a
structurally valid envelope: checking only IV/Base64 grammar would still confuse
that legitimate raw text with a trusted stored ciphertext. The problem is lost
provenance at raw ingress, not merely a missing regular expression.

Why hidden: the encryption switch/key availability remain true; the raw string is
nonempty, so the SQL builder treats it as successful protection. The path emits no
crypto failure and the existing no-double-wrap regression intentionally tests only
an actual already-produced envelope. The marker/algorithm parity gate establishes
matching parameters, not safe discrimination at raw-input boundaries.

Reproducer and provenance:

- `probes/windows-prefix-sql-migration.ahk` includes the actual cipher, actual JSON
  and generated query renderer, and verbatim extracted SQL/migration/literal-
  encoder functions. Only native hash/AES/Base64 boundaries record synthetic
  data. It writes no config/database/user file and touches no real clipboard,
  registry or secret store. It is **unexecuted**; expected output is retained in
  `probes/windows-prefix-sql-migration.json`. It asserts ordinary raw text uses
  two native encryption calls (text/JSON); marker raw text uses only one and
  appears literally in SQL; encrypt conversion remains unchanged; decrypt
  conversion refuses.
- Inspected macOS actual-owner composition:
  `docs/audits/platform-parity/2026-11-04-flows/macos-crypto/probes/cipher-prefix.lua` and
  `logs/cipher-prefix.txt`. Real `modules.keystats.text_cipher` and real
  `sqlite_writer.build_inserts` show ordinary text protected, malformed prefix
  text literal in SQL, and valid-envelope-lookalike literal interpreted as decoded
  fixture content; only native shell/hash/JSON seams record synthetic data.
- Inspected Linux actual-owner composition:
  `docs/audits/platform-parity/2026-11-04-flows/linux-crypto/probes/marker-collision.lua` and
  `logs/marker-collision.log`. It uses genuine native EVP with a synthetic key,
  real shared cipher, real raw SQL composer and real migration runner. Ordinary
  binary-safe text round-trips; prefix literals bypass native encryption and enter
  SQL; a prefix-looking row aborts decrypt migration. The named SQL artifacts hold
  synthetic canaries only. These are comparator executions, not native Windows tests.

Regression direction: raw ingress must always encrypt nonempty plaintext even
when its bytes resemble a valid envelope. Preserve historical migration/retry
idempotence through explicit trusted stored-value ownership, not a content prefix
on the raw API. Exercise malformed prefix, fully shaped lookalike, quotes/newlines/
NUL/non-ASCII, disabled mode, actual existing ciphertext, failed native crypto and
restart/migration. Assert raw SQL never contains the synthetic protected canary,
decryption recovers the exact originally typed literal, and decrypt migration
completes without weakening rejection of genuinely corrupt stored ciphertext.

## Entire user-flow map

| User entry / action                            | Owner, prerequisites, side effect and receipt                                                                                                                                                                                                                                                                                                                                                                                                                                                       |
| ---------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Metrics encryption toggle                      | `windows/ui/menu/menu_metrics_actions.ahk:75` delegates to `_MetricsToggleEncryptionAndReload`; `infra/metrics/metrics_filters.ahk:176` requires a usable key before enabling, persists through the configuration owner, publishes the cipher flag and uses strict reload result. Unavailable encryption presents a dedicated error; no plaintext fallback is authorized.                                                                                                                           |
| Typing with encryption enabled                 | `KL_BuildInsertTyping` invokes cipher independently for text and events_json; native failures return empty, causing conversion refusal/retry instead of acknowledging an omitted event. The prefix branch is WCR-001. Other journal copies are the already known WM-002 and are not re-counted.                                                                                                                                                                                                     |
| Read/rebuild/decrypt                           | `keystats_reader_db.ahk:1188` normalizes encrypted events_json into MEMORY-only TEMP projection and refuses empty decrypt; current durable cache stores numeric counts, not clear event payload. Literal text is a protected column distinct from dashboard aggregate counts. No complete raw-text UI export flow was assumed.                                                                                                                                                                      |
| Toggle encryption on/off for existing history  | `keystats_text_migration.ahk:925` owns streamed staged rewrite, local device only, cached key, bounded slices, suspend/resume and exact marker receipt. On failure original data.sql remains untouched; success is withheld until durable marker acknowledgment. No user password or manual key-rotation control is exposed here.                                                                                                                                                                   |
| Restore/sync metrics from another device       | Key is derived from this device's MachineGuid, not from envelope version. Migration skips rows with another device id (`:403`); the same envelope schema does not promise cross-machine decryption. Config backups exclude metrics, so they are not a metrics-key export/restore mechanism.                                                                                                                                                                                                         |
| Add/edit API entry                             | `ui/menu/menu_llm/menu_api_entries.ahk:348` masked Password prompt; token is not Trimmed except the declared exchange-provider normalization. Each modal prompt rechecks original private-source owner. `_LLM_Menu_SerializeApiEntries:1326` seals live nonempty tokens and validates genuine current-user DPAPI envelopes before the joint WAL captures API/config targets.                                                                                                                        |
| Save failure / key rotation / delete API entry | Native protect failure, malformed envelope or transaction failure refuses the complete candidate and preserves previous disk/RAM authority. API CRUD uses `LLM_Menu_CommitApiEntriesMutation` with sibling config/API source ownership; old/new clear runtime maps are not the persisted credential image. Native tests cover rollback/refusal but were not executed here.                                                                                                                          |
| Load legacy or DPAPI API token                 | `api_token_crypto.ahk:105` treats non-prefixed values as legacy cleartext, malformed DPAPI prefix as false, and structurally valid but unreadable DPAPI blobs as the original envelope, preserving recoverability. A subsequent save validates usability and may refuse until the user re-enters/removes a foreign/unreadable key. This is identity-bound storage, not portable credentials.                                                                                                        |
| Proxy with embedded credentials                | `adapters/proxy_override.ahk:173` seals the full canonical relay through DPAPI; `:185` explicitly refuses an envelope that cannot be unsealed, rather than treating it as a route. Maintainer decision routes the clear relay only into a worker's private environment, not the driver environment/log/command/receipt. Native transport verification was not run.                                                                                                                                  |
| Exchange/service-account API credentials       | `api_token_exchange.ahk:405` caches by provider and exact stored key; start is deferred off the requester, checks pause before signing, normalizes/validates schema and reports exact safe refusal. Access tokens remain RAM-only with monotonic expiry and bounded retry cooldown; request callbacks are fenced by their actual remote callers. `rs256_signer.ahk` validates key shape/CRT/signature consistency and wipes mutable key buffers, while original immutable PEM remains caller-owned. |
| Generic selection/file encrypt/decrypt         | No corresponding production Windows action/menu owner was established by complete encryption-symbol/action searches. Windows text cipher here is metrics storage, not an arbitrary selected-text cipher. macOS Encryptor droplet is the separately documented bundled application; its Windows/Linux absence is already in TODO and not a new finding.                                                                                                                                              |

## Dependencies, selective scope and intentional/unknown rationale

| Difference / policy                 | Provenance and status                                                                                                                                                                                          | User effect / macOS and Linux counterparts                                                                                                                                                                                                                                                                                                      |
| ----------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| CNG vs external/native primitives   | Explicit Windows cipher header: Windows has no default openssl; native AES/PBKDF2 avoids spawning a process per value. Parameters match shared text_crypto; gate executed.                                     | Windows uses bcrypt/crypt32, macOS cipher uses OpenSSL shell boundary, Linux uses native EVP plus its derivation owner. Native prerequisite failures must refuse encryption; equal format is not proof of equal native timing.                                                                                                                  |
| Metrics key ownership               | Explicit cipher threat model: machine-derived key, durability preferred over secret-vault dependence. No user password/reset/key-export UI in this path.                                                       | MachineGuid on Windows, hardware UUID on macOS, machine-id on Linux. Existing data can be unreadable after identity loss; no portable restoration claim. Same-machine code can derive keys. Fixed public DPAPI entropy is not isolation from another process of the same user.                                                                  |
| Selected columns only               | Explicit SQL/cipher/migration rationale: text/events_json encrypted; aggregate columns deliberately clear for queries.                                                                                         | Selective protection exists across drivers. Treat a promise of whole-database encryption or authenticated storage as unsupported; do not re-count deliberately clear numeric/aggregate columns as a new gap. Journal plaintext is the separate WM-002.                                                                                          |
| CBC without authentication          | Actual shared AES-256-CBC/PKCS7 envelope has no MAC/AEAD tag. No explicit tamper-authentication guarantee found.                                                                                               | Wrong key/truncation commonly refuses; a modified valid-padding CBC ciphertext can decode to changed bytes. This audit does not claim tamper-proof storage, nor promote absence of an unstated integrity property into G1–G5. Cryptographic redesign is outside this audit.                                                                     |
| Live API credentials at rest        | Explicit DPAPI module contract, parser/serializer checks, native identity binding.                                                                                                                             | Windows API file is DPAPI-sealed; macOS stores Keychain references and Linux secret-service references in private file. GUI/native consent/service prerequisites differ. These are real secret backends, not missing generic API-key persistence.                                                                                               |
| Foreign/corrupt DPAPI key           | Explicit preservation branch retains opaque envelope; current-user envelope validation refuses destructive/unsafe re-persistence.                                                                              | Backups/synced config are not portable Windows keys; re-enter/delete the key when Windows cannot recover it. macOS/Linux references likewise depend on corresponding native secret store. The loader's preserved opaque blob may yield an auth refusal, not automatic secret recovery.                                                          |
| Retired provider legacy plaintext   | Explicit Windows parse comment says retired row is never usable and written back as is; serializer copies it unchanged. Linux retired-provider test deliberately preserves raw legacy token and future fields. | This is a compatibility/selective-scope exception. It can retain plaintext for an unavailable provider, but should not be mislabeled absent DPAPI. Preservation intent is explicit; why that exception is preferred over sealing/deleting old secret material is not separately documented. It is reported as a scope caveat, not a new defect. |
| Reserved `dpapi:` raw token         | Explicit Encrypt comment refuses user token resembling persistence marker; failures are loud and transactional.                                                                                                | A custom provider requiring that exact raw prefix cannot be saved through this API. This is intentional format admission, unlike WCR-001's silent successful handling of unrestricted typed text. Other backends have their own reserved reference formats.                                                                                     |
| Marker-based historical idempotence | Explicit no-double-wrap comments and real native regression test for produced ciphertext.                                                                                                                      | Repeated historical conversion should not double-encrypt trusted envelopes. That valid invariant does not authorize treating arbitrary raw typing as trusted ciphertext; WCR-001 needs ingress provenance, not deletion of the idempotence test.                                                                                                |

## Counter-sweeps and refutations

`probes/pass-ledger.json` records discovery P0 followed by **two consecutive dry
passes P1 and P2**, with no additional confirmed actionable root cause in scope.
Dry is a coverage statement for these named boundaries, not an assertion that
unexecuted native paths are bug-free.

- API plaintext-fallback candidate refuted for live rows: serialization requires
  successful DPAPI round-trip before WAL; current tests exercise identity/empty/
  malformed protector output and preserve old images. These tests were read, not
  run. Retired rows are an explicit separate exception as described above.
- DPAPI failed-decrypt wiping candidate refuted: original envelope is retained,
  malformed markers refuse, and current serializer does not silently replace the
  old key with empty or plaintext on failure. This does not promise a foreign key
  remains usable or that an unrelated API save will succeed around it.
- “CryptoSha256 silently falls back to DJB2” refuted on current source: the
  adapter returns empty/error on provider failure, with native handle finally
  cleanup; historical fallback exists only in explanatory comments/tests.
- “Every imported row must be rekeyed” refuted: foreign device key domains are
  explicitly skipped. Local rewrite has staged publication and durable posture
  marker; a failed decrypt must preserve the original, not erase a row.
- “Stricter envelope regex alone fixes raw-input bypass” refuted: a legitimate
  raw string may be indistinguishable in bytes from a full valid envelope.
  Use source/ownership context, and retain trusted-ciphertext idempotence controls.
- Password-field filters do not supply encryption passwords: their privacy
  admission is a separate subsystem. They were cross-linked, not re-audited as
  a cryptographic key source.
- Late exchange completion after changed credential is not itself proof of stale
  key use: the slots are keyed by provider/exact key, and actual remote callback
  ownership must authorize emission. No new unguarded native-interleaving case
  was promoted without a reachable current-source reproduction.

## G4 and memory watch-list

**G4 is unmeasured on Windows.** No native runtime/logs were accessed; real user
paths/logs are explicitly outside this task. The native source's “fastest” and
“about 2 ms” comments are not measurements from this audit. PBKDF2 600,000 rounds
are cached once, and failure is latched, avoiding deliberate per-row derivation;
first-use key availability/DPAPI batch serialization can still cost synchronous
work. Native cold enable/first flush and large-entry save timing remains required
before making a latency guarantee. No G4 finding is asserted from static cost.

| Memory/resource item | Source-backed status / evidence gap                                                                                                                                                                                                                                                                          |
| -------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| Cipher session key   | One cached 32-byte Buffer plus failed-derivation latch; per-row UTF-8/IV/output Buffers released by AHK lifetime. No memory high-water measurement performed.                                                                                                                                                |
| CNG handles          | AES/hash/PBKDF2 close provider and child handles in finally; signer wipes mutable buffers/limbs. Exact native refusal/zero-output allocation behavior was not exercised.                                                                                                                                     |
| DPAPI allocations    | Successful normal paths copy out then LocalFree. Early zero-size/zero-pointer success branches are a native-boundary watch item, not a reproduced leak claim. No real account blob was created or decrypted.                                                                                                 |
| Access-token cache   | Exact provider/raw-key slots survive for process lifetime; old keys can remain in RAM after rotation. No bounded production growth/high-water proof was established, so no G1 exhaustion claim. Plaintext runtime credentials are necessary to emit requests; this is distinct from at-rest confidentiality. |
| Migration buffers    | Streamed read chunks plus one statement and bounded statement slices; staged-file ownership and suspend/resume are explicit. Huge individual statements/native scheduling and stable-flush timing remain unexecuted.                                                                                         |

## Verification, receipts and remaining gaps

Executed here:

- Pinned Node 22.22.2 `tools/test/find-false-greens.cjs`: within baseline, 0 vs 0.
  It is a mechanical scan, not proof that native fixture behavior is complete.
- Pinned Node 22.22.2 `tools/test/test-text-crypto-envelope-parity.cjs`: marker,
  AES-256-CBC, 600,000-round PBKDF2/salt and sizes agree across all drivers.
- Exact source/hash comparison to audited pin for eleven owned cipher/API/native/
  shared files: all unchanged. `probes/source-receipt.json` records hashes.
- Windows AHK artifact generation preserves actual owners and UTF-8 BOM + LF;
  no AHK execution, parse success or CNG crypto result is claimed.
- macOS/Linux counterpart probe source and logs listed above inspected directly;
  their fake/native primitive distinctions are retained in this report.

Native tests discovered/read: `test_keystats_text_cipher.ahk`,
`test_keystats_text_migration.ahk`, `test_llm_api_entries_transactions.ahk`,
`test_dpapi_blob_size.ahk`, `test_dpapi_decrypt_safe.ahk`,
`test_llm_api_token_exchange.ahk`, `test_llm_rs256_signer.ahk`,
`test_proxy_override.ahk`, encrypted reader/cache and conversion-retry tests.
None was reported green without running its native owner.

The repository's canonical audit CLI only accepts dated ahk/hammerspoon report
locations and nonempty G1–G5 arrays. This task explicitly requires scratch
windows-crypto scope and confidentiality outside those guarantees; its original
validator is not modified or weakened. A separate structural check validates the
requested manifest, including empty guarantees only with an explicit additional
property. Root integration owns the final report-path projection.

Coverage gaps: native AHK parser/execution; actual CNG padding/UTF-8/DPAPI account
and backup recovery; live menu/reload boundaries; native private API files/WAL and
proxy workers; full RSA native corpus; performance/memory high-water; user-facing
failure visibility on real Windows. No real user secret, file, clipboard, registry,
credential service, network request or OS permission state was touched. No
production/test changes, commit or push occurred.
