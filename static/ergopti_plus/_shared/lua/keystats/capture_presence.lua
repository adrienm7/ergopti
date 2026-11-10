--- _shared/lua/keystats/capture_presence.lua

--- ==============================================================================
--- MODULE: Capture-Process Presence
--- DESCRIPTION:
--- The screen_recording_start / screen_recording_end rows of events_av for the
--- Lua drivers: whether a known screen-capture or conferencing program is
--- running. Port of the Windows KL_AV_ScanCapture and KL_AV_ReduceCaptureSample
--- (keystats_av_state.ahk), whose reducer it mirrors.
---
--- FEATURES & RATIONALE:
--- 1. Presence, not activity: as on Windows, a running program is the signal;
---    no screen, window or audio content is read.
--- 2. Same reducer: an unknown sample (an unreadable process list) keeps the
---    last accepted state; the start keeps the first program seen, and the end
---    names the program the start named.
--- 3. One list per OS of the names each OS reports: the Linux kernel's 15-byte
---    process name (/proc/<pid>/comm) and the macOS bundle identifier. The
---    Windows executable list stays in its AHK owner (KLAVConst.CAPTURE_EXES).
--- 4. No OS calls: each driver lists its processes at the shared timing
---    [keystats] av_state_slow_tick_ms and passes the names in.
--- ==============================================================================

local M = {}

--- The events_av kinds this module writes and the metadata keys each carries.
M.KINDS = {
	screen_recording_start = { "exe" },
	screen_recording_end = { "exe" },
}

--- Known capture and conferencing programs, as each OS names a running process.
--- Linux: the kernel truncates /proc/<pid>/comm to 15 bytes, so long names are
--- listed truncated. macOS: bundle identifiers, the stable name of an app.
M.PROGRAMS = {
	linux = {
		"obs", "zoom", "teams-for-linux", "webex", "discord", "simplescreenrec", "kazam",
		"peek", "vokoscreenng", "kooha", "gpu-screen-reco", "wf-recorder", "wl-screenrec",
		"flameshot", "spectacle",
	},
	macos = {
		"com.obsproject.obs-studio", "us.zoom.xos", "com.microsoft.teams", "com.microsoft.teams2",
		"com.cisco.webexmeetingsapp", "cisco-systems.spark", "com.hnc.discord", "com.loom.desktop",
		"com.techsmith.camtasia2023", "com.techsmith.camtasia2024", "com.techsmith.camtasia2025",
		"com.wulkano.kap", "pl.maketheweb.cleanshotx", "net.telestream.screenflow10",
	},
}

--- Builds a lookup set over one OS's program list.
--- @param os_name string "linux" or "macos".
--- @return table set { [lowercase name] = true }
function M.program_set(os_name)
	local list = assert(M.PROGRAMS[os_name], "no capture-program list for " .. tostring(os_name))
	local set = {}
	for _, name in ipairs(list) do set[name] = true end
	return set
end

--- The typed sample of one process listing.
--- @param names table|nil Process names (nil: the listing failed).
--- @param set table program_set() result.
--- @return table sample { status = "active"|"inactive"|"unknown", exe }
function M.sample(names, set)
	if type(names) ~= "table" then return { status = "unknown" } end
	for _, name in ipairs(names) do
		local key = type(name) == "string" and name:lower() or nil
		if key and set[key] then return { status = "active", exe = key } end
	end
	return { status = "inactive" }
end

--- The Windows capture reducer (KL_AV_ReduceCaptureSample).
--- @param previous_active boolean Last accepted state.
--- @param previous_exe string Program the last start named ("" when inactive).
--- @param sample table sample() result.
--- @return table { accepted, changed, next_active, next_exe }
function M.reduce(previous_active, previous_exe, sample)
	local result = { accepted = false, changed = false, next_active = previous_active, next_exe = previous_exe }
	if type(sample) ~= "table" then return result end
	if sample.status == "inactive" then
		result.accepted, result.changed, result.next_active, result.next_exe = true, previous_active, false, ""
		return result
	end
	if sample.status ~= "active" or type(sample.exe) ~= "string" or sample.exe == "" then return result end
	result.accepted, result.changed, result.next_active = true, not previous_active, true
	result.next_exe = previous_active and previous_exe or sample.exe
	return result
end

--- Creates one presence tracker.
--- @param emit fun(kind:string, fields:table) Receives each transition.
--- @return table tracker { observe(sample, app) -> boolean accepted, close(app), active() }
function M.new(emit)
	assert(type(emit) == "function", "the capture tracker needs a recorder")
	local active, exe = false, ""
	local self = {}

	function self.observe(sample, app)
		local transition = M.reduce(active, exe, sample)
		if not transition.accepted then return false end
		if transition.changed then
			local named = transition.next_active and transition.next_exe or exe
			emit(transition.next_active and "screen_recording_start" or "screen_recording_end", { app = app, exe = named })
		end
		active, exe = transition.next_active, transition.next_exe
		return true
	end

	--- Closes an open interval when the collector stops, as Windows KL_AV_Stop does.
	function self.close(app)
		if active then emit("screen_recording_end", { app = app, exe = exe }) end
		active, exe = false, ""
	end

	function self.active() return active end

	return self
end

return M
