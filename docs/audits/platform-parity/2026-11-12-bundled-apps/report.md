# Bundled apps: App Cloner and Encryptor

Audited source: `a7cb1c1e` (`claude/ergopti-todo-parity-audit`, on `dev`
`c250f655`). Date: November 12, 2026.

## Scope

The Encryptor and App Cloner on macOS (`macos/apps/Encryptor.app`,
`macos/apps/App Cloner.app`) and Linux (`linux/apps/`,
`linux/ui/bundled_apps.lua`) against the Windows reference (`windows/apps/`),
with the shared data `_shared/data/encryptor/format.json` and
`_shared/data/app_cloner/families.json`.

Checked and kept:

- **Container and KDF:** the magic, salt size, AES-256-CBC, PBKDF2-SHA256 at
  600,000 iterations and the key/IV split match `format.json` on all three.
- **Staged write:** a wrong password or a corrupted file keeps an approved
  destination byte for byte, and the stage is removed.
- **Passwords:** never on a command line, and never logged.
- **Prompts:** the order is overwrite, then password, then confirmation.
- **Destination:** the `.enc` rule ignores case, and the `_decrypted` fallback
  is the same on all three.
- **App Cloner:** family detection on Windows and Linux reads the catalogue.
  Launcher and desktop-entry quoting are correct, and a taken name gives the
  new clone its own profile.

## Fixed

| Id      | OS           | Sequence                                                    | Windows                                                      | Before                                                                      | Regression                      |
| ------- | ------------ | ----------------------------------------------------------- | ------------------------------------------------------------ | --------------------------------------------------------------------------- | ------------------------------- |
| BAP-001 | macOS, Linux | Decrypt `foo.enc` next to a folder `foo`, approve overwrite | `MoveFileExW` refuses to replace a folder: failure dialog    | « File decrypted », the plaintext hidden as `.foo.XXXXXX` inside the folder | `bap-001-folder-destination`    |
| BAP-002 | macOS        | Clone Chrome, Edge, Brave or Firefox                        | Private profile (`--user-data-dir`, `--no-remote --profile`) | The clone ran on the main profile and opened in the running browser         | `bap-002-macos-browser-profile` |
| BAP-003 | macOS        | Drop three files, cancel the first overwrite                | That file is skipped, the next ones are processed            | Error -128 ended the whole batch                                            | `bap-003-overwrite-cancel`      |
| BAP-005 | Linux        | Clone with `~/Documents/x`, or a typo such as `https:/x`    | — (see Open)                                                 | `~` refused as a bad URL; scheme typos accepted, failing at launch          | `bap-005-open-item`             |
| BAP-006 | Linux        | Clone the same name twice                                   | The second shortcut is « Name (2) »                          | Two identical menu entries                                                  | `bap-006-duplicate-name`        |
| BAP-007 | macOS, Linux | Encrypt into a read-only folder, or onto a folder           | The system's reason follows « Encryption failed »            | Only « Encryption failed », read like a wrong password                      | `bap-007-failure-reason`        |

BAP-002 adds the macOS executable names « google chrome », « microsoft edge »
and « brave browser » to the catalogue; a web URL opens in the clone itself,
as an `--app` window for Chromium. BAP-007 adds two keys in the 21 locales and
shows them for every refusal but OpenSSL's own (a wrong password or a
corrupted file, which the message already names). The macOS AppleScript
changes (BAP-003, BAP-007) need `main.scpt` recompiled on the Mac
(`tools/dev/recompile-applescripts.py`).

## Open

- **BAP-004 (all three, low-medium):** a VSCodium or VS Code Insiders clone is
  linked to VS Code's settings (`Code/User`) and extensions
  (`{home}/.vscode/extensions`, a shared catalogue argument); their own
  folders are `VSCodium/User` with `~/.vscode-oss` and `Code - Insiders/User`.
  Proposal: per-executable settings and extensions folders in
  `families.json`, read by the three drivers. The Windows reader changes too,
  so this needs a coordinated decision.
- **BAP-005 on Windows (report):** `_AppCloner_InvalidOpenItem` accepts the
  same scheme typos Linux accepted, and no `~` path.
- **BAP-008 (Linux, low, plausible):** the Encryptor's desktop entry declares
  `MimeType=application/octet-stream;`, which offers it in « Open with » for
  any file (Windows offers it through Send To). On a desktop where no other
  application handles that type, it could become the default opener.
  Registering only `.enc` would end that risk but also drop « Open with »
  for plain files: a maintainer decision.
- `encryptor_convert.sh` relies on the default OpenSSL digest for PBKDF2
  (SHA-256 on OpenSSL 1.1+ and the LibreSSL of macOS 10.15+). Passing
  `-md sha256` would make that explicit.

Native receiving (a real clone and Encryptor run on a Mac and a Linux
session) is unqualified.
