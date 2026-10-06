--- platform/window_switch_worker.lua

--- Fixed X11 worker: blocking native queries run only in an owned child group.
-- The parent supplies the authoritative driver/shared search path as literal argv.
require("compat.utf8").install()
local Shell = require("adapters.shell_runner")
local Policy = require("cursor_window_policy")
local LIMIT = 65536
local Native = require("luv")
local Constants = Native.constants
local files, directory = {}, nil
local SNAPSHOT = [=[set -eu
root=$(xwininfo -root -int | sed -n 's/^xwininfo: Window id: \([0-9][0-9]*\) .*/\1/p')
case "$root" in ''|*[!0-9]*) exit 1;; esac
printf 'source\nROOT=%s\npointer\n' "$root"
xdotool getmouselocation --shell
printf 'monitors\n'
xrandr --listmonitors
printf 'active\n'
xdotool getactivewindow
printf 'focus\n'
focus=$(xdotool getwindowfocus -f)
depth=0
while :; do
    case "$focus" in ''|*[!0-9]*) exit 1;; esac
    printf '%s\n' "$focus"
    [ "$focus" != "$root" ] || break
    depth=$((depth + 1))
    [ "$depth" -le 64 ] || exit 1
    focus=$(xwininfo -int -tree -id "$focus" | sed -n 's/^[[:space:]]*Parent window id: \([0-9][0-9]*\) .*/\1/p')
done
printf 'end_focus\n'
printf 'desktop\n'
xdotool get_desktop
printf 'stacking\n'
stacking=$(xprop -root _NET_CLIENT_LIST_STACKING)
case "$stacking" in '_NET_CLIENT_LIST_STACKING(WINDOW): window id # '*) ;; *) exit 1;; esac
ids=${stacking#*# }
printf '%s\n' "$ids"
old_ifs=$IFS
IFS=', '
for id in $ids; do
    digits=${id#0x}
    case "$id:$digits" in 0x*:*) ;; *) exit 1;; esac
    case "$digits" in ''|*[!0-9a-fA-F]*) exit 1;; esac
    printf 'window %s\n' "$id"
    if geometry=$(xdotool getwindowgeometry --shell "$id" 2>/dev/null) &&
       desktop=$(xdotool get_desktop_for_window "$id" 2>/dev/null) &&
       props=$(xprop -id "$id" WM_STATE _NET_WM_STATE _NET_WM_WINDOW_TYPE 2>/dev/null) &&
       title=$(xdotool getwindowname "$id" 2>/dev/null); then
        printf '%s\nDESKTOP=%s\n' "$geometry" "$desktop"
        eligible=0
        case "$props" in *'window state: Normal'*) eligible=1;; esac
        case "$props" in *_NET_WM_STATE_HIDDEN*|*_NET_WM_WINDOW_TYPE_DESKTOP*|*_NET_WM_WINDOW_TYPE_DOCK*|*_NET_WM_WINDOW_TYPE_TOOLTIP*|*_NET_WM_WINDOW_TYPE_MENU*|*_NET_WM_WINDOW_TYPE_NOTIFICATION*) eligible=0;; esac
        [ -n "$title" ] || eligible=0
        printf 'ELIGIBLE=%s\n' "$eligible"
    else
        printf 'UNAVAILABLE=1\n'
    fi
    printf 'end_window\n'
done
IFS=$old_ifs
printf 'end_snapshot\n']=]

local function query()
	local accepted, packet = Shell.exec_checked("timeout --foreground 1 sh -c " .. Shell.quote(SNAPSHOT) .. " 2>/dev/null")
	if accepted ~= true or #packet > LIMIT then return nil end
	local parsed = Policy.parse_snapshot(packet)
	if not parsed or not parsed.root then return nil end
	return parsed, packet
end

local function exact(stat, identity, kind, mode)
	return type(stat) == "table" and stat.dev == identity.dev and stat.ino == identity.ino
		and stat.type == kind and stat.mode % 512 == mode
end

local function transport_current()
	if not directory or not exact(Native.fs_lstat(directory.path), directory, "directory", 448) then return false end
	for path, identity in pairs(files) do
		if not exact(Native.fs_lstat(path), identity, "file", 384) then return false end
	end
	return true
end

local function with_file(path, flags, operation)
	local identity = files[path]
	if not identity or not exact(Native.fs_lstat(path), identity, "file", 384) then return nil end
	-- Never truncate on open or block on a FIFO. Validate pathname and held
	-- descriptor authority independently before reading or mutating contents.
	local fd = Native.fs_open(path, flags + Constants.O_NONBLOCK, 0)
	if not fd then return nil end
	local acquired = Native.fs_fstat(fd)
	local ok, value = pcall(function()
		if not exact(acquired, identity, "file", 384)
			or not exact(Native.fs_lstat(path), identity, "file", 384) then return nil end
		return operation(fd, acquired)
	end)
	-- Content authority and descriptor authority are separate: even a rejected
	-- foreign inode/type is the exact descriptor this acquisition must close.
	local current = Native.fs_fstat(fd)
	local closed = type(acquired) == "table" and type(current) == "table"
		and current.dev == acquired.dev and current.ino == acquired.ino and current.type == acquired.type
		and Native.fs_close(fd) == true
	return ok and closed and value or nil
end

local function read(path)
	return with_file(path, Constants.O_RDONLY, function(fd, stat)
		if stat.size < 0 or stat.size > LIMIT then return nil end
		local packet = stat.size == 0 and "" or Native.fs_read(fd, stat.size, 0)
		return packet and #packet == stat.size and packet or nil
	end)
end

local function write(path, packet)
	if type(packet) ~= "string" or #packet > LIMIT then return false end
	return with_file(path, Constants.O_WRONLY, function(fd)
		return Native.fs_write(fd, packet, 0) == #packet and Native.fs_ftruncate(fd, #packet) == true
	end) == true
end

local function acquire_transport(packet, path)
	if type(packet) ~= "string" or type(path) ~= "string" or path == "" or path:find("%z") then return false end
	local identities = {}
	for record in (packet .. ","):gmatch("([^,]*),") do
		local dev, ino = record:match("^(%d+):(%d+)$")
		dev, ino = tonumber(dev), tonumber(ino)
		if not dev or not ino or dev > 9007199254740991 or ino > 9007199254740991 then return false end
		identities[#identities + 1] = { dev = dev, ino = ino }
	end
	if #identities ~= #Policy.TRANSPORT_NAMES + 1 then return false end
	directory = identities[1]; directory.path = path
	for index, name in ipairs(Policy.TRANSPORT_NAMES) do files[path .. "/" .. name] = identities[index + 1] end
	return transport_current()
end

local function canonical_digest(path)
	if path == "" then return "NONE\n" end
	local accepted, packet = Shell.exec_checked("timeout --foreground 1 sh -c " .. Shell.quote('sha256sum < "$1"')
		.. " sh " .. Shell.quote(path) .. " 2>/dev/null")
	local digest = accepted == true and packet:match("^([%da-f]+)  %-\n$") or nil
	return digest and #digest == 64 and digest .. "\n" or nil
end

local function request_permit(request, permit, phase)
	if not write(request, "READY " .. phase .. "\n") then return false end
	local deadline = Native.hrtime() + 2000000000
	repeat
		local receipt = read(permit)
		if receipt == "REVOKED\n" then return false end
		if receipt == "PERMIT " .. phase .. "\n" then return true end
		Native.sleep(10)
	until Native.hrtime() >= deadline
	return false
end

local function run()
	local stage, output, reference, source = arg[1], arg[2], arg[3], arg[4]
	local request, permit, digest_path, config_path = arg[5], arg[6], arg[7], arg[8]
	if not acquire_transport(arg[9], arg[10]) or os.getenv("DISPLAY") ~= source then return false end
	if reference ~= directory.path .. "/initial" or request ~= directory.path .. "/request"
		or permit ~= directory.path .. "/permit" or digest_path ~= directory.path .. "/digest"
		or output ~= directory.path .. "/" .. (stage == "snapshot" and "initial" or "acknowledged") then return false end
	if stage == "snapshot" then
		local current, packet = query()
		local digest = current and canonical_digest(config_path)
		return digest ~= nil and write(digest_path, digest) and write(output, packet)
	end
	if stage ~= "focus" then return false end
	local first = Policy.parse_snapshot(read(reference))
	local target = first and Policy.candidate(first)
	local current = query()
	if not target or not Policy.revalidated(first, current, target) or os.getenv("DISPLAY") ~= source then return false end
	-- The parent rechecks canonical ownership, input generation and pause after
	-- the child query; a stale polling receipt never authorizes activation.
	if not request_permit(request, permit, 1) then return false end
	current = query()
	if not Policy.revalidated(first, current, target) or not request_permit(request, permit, 2) then return false end
	local captured_digest, current_digest = read(digest_path), canonical_digest(config_path)
	if not current_digest or current_digest ~= captured_digest or read(permit) ~= "PERMIT 2\n"
		or os.getenv("DISPLAY") ~= source or not transport_current() then return false end
	-- Filesystem, evdev and X11 offer no joint atomic transaction. These fresh
	-- receipts authorize this dispatch; pause/revocation kills the exact group
	-- and withdraws the permit. Independent final input-focus ACK is still required.
	local accepted = Shell.exec_checked("timeout --foreground 1 xdotool windowactivate --sync " .. tostring(target) .. " >/dev/null 2>&1")
	if accepted ~= true then return false end
	local final, packet = query()
	return os.getenv("DISPLAY") == source and Policy.acknowledged(first, final, target) and write(output, packet)
end

-- No arbitrary native output, paths, client names or titles reach the caller.
local ok, accepted = pcall(run)
os.exit(ok and accepted == true and 0 or 1)
