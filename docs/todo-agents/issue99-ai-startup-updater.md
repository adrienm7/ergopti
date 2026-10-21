<!-- docs/todo-agents/issue99-ai-startup-updater.md -->

# Issue #99: AI startup, local servers, update flow and other warnings (macOS)

Log of the report: v1.0.4 (4a12db2fae), plus a 1.0.3 session at 09:32 to 09:34. The Karabiner lease,
swallowed keys, ISO key, event tap, Accessibility observer and KC log lines belong to
[issue99-karabiner-input.md](issue99-karabiner-input.md).

## Done (on dev and origin/dev)

- `c25c0d65c4` fix(macos): read the diagnostics configuration where macOS keeps it. The
  configuration probe called `config_paths.config()`, which only Linux has, so it answered "error"
  on every Mac (`healthcheck ... helpers.lua:322`, `probes.configuration.state error`).
- `5b730d577a` fix(macos): turn the AI off with a warning when the model download is declined. The
  two `startup_ctrl` errors were the user closing the Ollama download prompt for `qwen3.5:2b`
  (09:52:48 and 09:54:17 dialog, error 3 to 9 s later). Each ERROR opened the error window. Now a
  warning names the cause, and the deferred settlement (terminal delivered inside its own
  requirement task, finished by the armed observer 9 ms later) logs at INFO.
- `5693e20294` fix(macos): log a gesture settings read cancelled by shutdown at INFO.
- `aa0419ec53` fix(macos): name the refused system proxy mode in the download admission log.
- `c2b8062eb5` fix(macos): check the AI runtime config.toml selects at boot. The boot bootstrap read
  an hs.settings key nothing writes, so an Ollama or API user got the MLX check and the "MLX is not
  installed, the AI stays off" notice at every start (the 5 `mlx_deps` and 5
  `menu_llm.runtime_offer` warnings).
- `34ef206a96` fix(llm): probe local AI servers at the IPv4 loopback literal (oMLX not found, all
  three drivers share the catalogue). The macOS sweep also logs each server's answer at DEBUG.
- `3071764155` fix(macos): read the releases Atom feed when the update check gets no API list.
- `fbf9c59656` fix(updater): refuse a feed-only Versions install with a warning (shared Lua and
  Windows).

## Per item

1. oMLX not found. Evidence: every sweep published "none answers" about 70 ms after the menu
   build, while #95 says oMLX ran and a hand-typed address failed too. oMLX serves
   `GET /v1/models` on 127.0.0.1:8000 (its Welcome window requires an API key, so a running server
   answers 401, which the sweep reports as `omlx=needs_key`); nothing answered, not even a 401.
   Ollama at 127.0.0.1 answered on the same Mac. Fix: the catalogue uses 127.0.0.1. Not proven
   without the Mac. Mac check: start oMLX, open the AI menu, read the new
   `Local server 'omlx' probe answered ...` DEBUG line. If it still says "nothing", run
   `curl -sS -o /dev/null -w '%{http_code}\n' http://127.0.0.1:8000/v1/models` and
   `lsof -nP -iTCP -sTCP:LISTEN | grep -i omlx` (port changed in oMLX settings?).
2. `startup_ctrl` Disabling LLM and unsettled cycle: fixed (see above). The AI staying off after a
   declined download is intended. Mac check: decline the prompt, no error window opens.
3. `model_switcher` switch_model failures (Qwen3.5-2B, Qwen3.5-0.8B): both are the Ollama pull
   refused by the opaque network admission, "The system proxy configuration cannot be used by
   this client": this Mac has a PAC, WPAD or SOCKS-only proxy setting. Deliberate policy (Ollama's
   Go client cannot follow an automatic proxy), so not changed; the log now names the mode. Mac
   check: `scutil --proxy`. If it is "Auto Proxy Discovery" with no WPAD server, decide whether the
   policy should admit WPAD (would be a policy change in `apply_opaque_system_network`,
   `macos/modules/llm/network-retry.sh`). Also open: `Ollama bootstrap failed (exit=137)` at
   09:51:58 with no output, 10 s after start, with an external Ollama (the script exits 0 at once
   when it resolves one): a SIGKILL of the native PTY worker child; needs the Mac
   (`log show --last 1h --predicate 'process == "ErgoptiPlus"'`, memory pressure: 398 MB free).
4. Update flow: the manual and background macOS checks now read the Atom feed when the API gives no
   list; Sparkle installs from the appcast. The Versions window cannot install from a feed-only list
   (no digests): that refusal is now a warning with the page's "try again" reason. Remaining
   option, not done: hand a Versions click on the channel's newest release to Sparkle when the list
   came from the feed (macOS only, needs a page phase and 21 locale strings). Windows and Linux
   checks keep the API only (their installs need API digests).
5. Other lines: `init` fatal abort at 09:40:03 is a second, unlaunched Hammerspoon instance that
   resolved `~/.config/ergopti_plus/` and was refused (correct, fail-closed; Mac check: which login
   item or app starts it). `gestures.conflicts` "Potential macOS system conflict" and the logger
   stall WARNING came from the 1.0.3 session; dev already logs them at INFO (8779da287f and the
   shed-lines rule). `download_window` error state follows the exit 137 above. `keymap` ignored
   window and `karabiner*` lines: other handoff.

## Checks run (Windows host)

macOS Lua targeted files and the menu_llm, ui and meta groups compared with a HEAD export (new
reds only in other agents' areas); Windows `--only "Release install"` and `--only "local server"`;
JS: changelog resilience, release install contract, channels, opaque admission, bundle payload,
menu manifest; Prettier and AHK encoding. Linux suite not runnable here: CI decides.

## TODO wording for the coordinator

- [ ] #99 oMLX: confirm on the Mac that the sweep now lists oMLX (DEBUG line per server).
- [ ] #99 proxy: read `scutil --proxy` on the Mac and decide whether WPAD without a server is
      admitted for Ollama pulls.
- [ ] #99 Ollama bootstrap exit 137 with an external Ollama: reproduce on the Mac.
- [ ] Versions window: let a feed-only list install the channel's newest release through Sparkle.
