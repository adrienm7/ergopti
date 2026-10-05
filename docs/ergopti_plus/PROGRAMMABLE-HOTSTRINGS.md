# Programmable dynamic hotstrings

The **Dynamic hotstrings** menu has a separate programmable source switch and
source actions. This source is executable personal code; it is separate from
the ordinary TOML hotstrings editor. The switch is off by default. Starting the
driver with the switch off does not execute an existing source. Enabling the
switch or explicitly choosing **Reload user source** loads the source. Preview
uses the declared `preview` text and never invokes a callback.
An absent or unreadable source refuses activation and offers repair. A valid
existing factory may deliberately return an empty rule list. Creating an example
does not activate it; enabling or reloading remains a separate action.

The configured personal directory contains `personal_dynamic_hotstrings.ahk`
on Windows and `personal_dynamic_hotstrings.lua` on macOS/Linux. Opening or
reloading preserves that file. **Create example** creates an absent file only;
it refuses to replace an existing file. Modify the example and reload it.

A source publishes an ordered list of rules. Each rule has exactly four fields:
`id`, `suffix`, `preview`, and `callback`. IDs are unique lowercase identifiers
matching `[a-z][a-z0-9_]*`. Suffixes are unique, case-sensitive, nonempty text.
The suffix excludes the configured magic key: `@clock` followed by the magic key
invokes the example. Preview is nonempty static text without line breaks. A
registered ordinary hotstring and the built-in personal-information resolver
have priority over programmable rules. Programmable rules have priority over
the generic repeat-key fallback. Earlier source rules win when suffixes overlap.
The dynamic activation interval is checked when physical input matches, using
the canonical `hotstrings.dynamic.user_code.time_activation_seconds` setting.
It measures the typing interval, not the duration of arbitrary user code.

## Windows example

```ahk
ErgoptiDynamicHotstrings(api) {
    return [Map(
        "id", "clock", "suffix", "@clock", "preview", "Current time",
        "callback", (context) => context["cancelled"].Call()
            ? false : FormatTime(, "HH:mm")
    )]
}
```

The factory receives `api["platform"] == "windows"`. Each callback receives a
Map with `id`, `suffix`, and the zero-argument `cancelled` function. A Windows
worker runs the exact admitted source in the packaged AutoHotkey interpreter.
Its factory is reconstructed for each callback, so source-local state is not a
persistent store. Source and compiled distributions use the same worker API.

## macOS and Linux example

```lua
return function(api)
    return {
        {
            id = "clock",
            suffix = "@clock",
            preview = "Current time",
            callback = function(context)
                if context.cancelled() then return false end
                return os.date("%H:%M")
            end,
        },
    }
end
```

The chunk returns a factory which receives `api.platform` (`"macos"` or
`"linux"`). A callback receives a table with `id`, `suffix`, and the
zero-argument `cancelled` function. Lua callbacks run after physical-input
admission, outside the native event-tap callback. They can call the normal
platform APIs available to user Lua code. Source-loaded closures survive until
reload; applications should use explicit storage if persistence matters.

Restoring recommended settings or clearing overrides also resets the switch and
activation interval. These configuration transactions preserve the executable
source. A refused transaction restores admitted Lua closures without rerunning
the factory. Restoration requires the same native owner, configuration revision
and source bytes; foreign changes retain a refused inverse for explicit retry.
A closed, idle source with no admitted callbacks can remain closed when its file
is absent or unreadable. That exception never authorizes activation.

## Callback result and ownership

Return a nonempty string to replace the captured suffix and its magic-key
completion. Literal `"0"`, Unicode, and multiline text remain text. Return
`true` after performing an action: this acknowledges the user callback and the
driver performs no further text mutation. The callback owns any trigger cleanup
or other side effects needed by that action. Return `false` to cancel; Lua may
also return `nil`. Empty strings and other types are execution errors.

For example, a Lua action can launch an application with its native platform API
and return `true`. An AHK action can call `Run(...)` and return `true`. Check
`context.cancelled()` immediately before the action. User actions are trusted
code; factory loading can itself execute code. Keep factories limited to rule
construction if loading should have no side effects.

The driver retains the exact source bytes, generation, input and destination
owner through execution and text publication. Reload, disabling, pause,
shutdown, further physical input, source edits, destination changes and secure
fields revoke driver output. Windows retains and cancels the exact worker Job
and its descendants. A Lua callback cannot be preempted safely within the same
interpreter; `context.cancelled()` is a cooperative check. The driver checks
again before publishing returned text. Cancellation cannot undo actions already
performed by a user callback, and it does not promise to cancel processes a Lua
callback launches independently.

Accepting a queued replacement does not mean its native output has completed.
The driver retains its output and cleanup owner until the native transaction,
timer and any clipboard restoration acknowledge settlement. A later refusal
drops unposted replacement text and releases any key already held by that
transaction. It cannot undo backspaces or other events already posted. Clipboard
restoration must retain its original owner when another application replaces the
clipboard; a refused cleanup remains pending for explicit retry.
That debt can continue to block reload or shutdown while ownership cannot be
proved; retry does not authorize overwriting another application's clipboard.

On Windows the physical completion has already reached the application;
cancelled or action-only callbacks leave that text alone. On platforms where the
native owner consumes the magic input, cancellation replays it only while the
original destination and input receipt remain current. A stale focus or later
physical input must never cause replay into a different target.

Load and execution failures are reported visibly with translated messages and
stable diagnostics. Source contents, returned text and private exception
messages are excluded from those diagnostics. A failed reload closes execution;
old metadata does not authorize old callbacks. Privacy and destination owners
must be available before callback execution or driver output is admitted.
