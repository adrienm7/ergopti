--- platform/vision/png_codec.lua

--- ==============================================================================
--- MODULE: PNG Codec (gray)
--- DESCRIPTION:
--- Decodes a PNG into the screen vision service's grayscale image and encodes a
--- grayscale image as a PNG, for the user workflows: an image a workflow embeds
--- becomes a matcher template, and a capture becomes a file a later step reads.
--- The deflate stream goes through the system zlib (libz.so.1) by the FFI.
---
--- FEATURES & RATIONALE:
--- 1. The shared gray: every pixel is auto_click_matcher.gray of its colour, so
---    a template scores against a capture exactly as a library image does.
--- 2. The common PNGs: 8-bit gray, gray with alpha, RGB, RGBA and palette,
---    non-interlaced, with the five row filters. Alpha is ignored: a template
---    is a screenshot of a button, opaque by nature.
--- 3. Bounded: a header over the caller's pixel bound, a truncated chunk or a
---    stream that does not inflate to the exact size is refused as
---    template_unreadable, never decoded partially.
--- ==============================================================================

local M = {}

local Matcher = require("shortcuts.engine.keep_awake.auto_click_matcher")

local SIGNATURE = "\137PNG\r\n\26\n"
-- The screen vision reasons this codec answers.
local REASON = { unreadable = "template_unreadable", unavailable = "capture_unavailable", refused = "capture_refused" }
--- Bytes per pixel of each supported colour type at bit depth 8.
local CHANNELS = { [0] = 1, [2] = 3, [3] = 1, [4] = 2, [6] = 4 }
--- zlib's Z_OK and its best-speed level, part of the zlib API.
local Z_OK = 0
local Z_BEST_SPEED = 1

local _zlib, _ffi = nil, nil

--- Loads zlib once.
--- @return table|nil zlib, table|nil ffi
local function zlib()
	if _zlib then return _zlib, _ffi end
	local ok_ffi, ffi = pcall(require, "ffi")
	if not ok_ffi then return nil end
	pcall(ffi.cdef, [[
		int uncompress(unsigned char *dest, unsigned long *destLen, const unsigned char *source, unsigned long sourceLen);
		int compress2(unsigned char *dest, unsigned long *destLen, const unsigned char *source, unsigned long sourceLen, int level);
		unsigned long compressBound(unsigned long sourceLen);
		unsigned long crc32(unsigned long crc, const unsigned char *buf, unsigned int len);
	]])
	local loaded, lib = pcall(ffi.load, "libz.so.1")
	if not loaded then return nil end
	_zlib, _ffi = lib, ffi
	return lib, ffi
end

--- Reads a big-endian 32-bit integer.
local function u32(bytes, at)
	local a, b, c, d = bytes:byte(at, at + 3)
	return ((a * 256 + b) * 256 + c) * 256 + d
end

--- Writes a big-endian 32-bit integer.
local function be32(value)
	return string.char(math.floor(value / 16777216) % 256, math.floor(value / 65536) % 256,
		math.floor(value / 256) % 256, value % 256)
end

--- The Paeth predictor of the PNG specification.
local function paeth(a, b, c)
	local p = a + b - c
	local pa, pb, pc = math.abs(p - a), math.abs(p - b), math.abs(p - c)
	if pa <= pb and pa <= pc then return a end
	if pb <= pc then return b end
	return c
end

--- Decodes a PNG into a grayscale image.
--- @param bytes string The PNG file.
--- @param max_pixels integer The largest width * height accepted.
--- @return table|nil image { width, height, pixels }
--- @return string|nil reason template_unreadable, or capture_unavailable when
---   zlib is missing.
function M.decode_gray(bytes, max_pixels)
	assert(type(max_pixels) == "number" and max_pixels > 0, "png_codec.decode_gray needs a pixel bound")
	if type(bytes) ~= "string" or bytes:sub(1, 8) ~= SIGNATURE then return nil, REASON.unreadable end
	local lib, ffi = zlib()
	if not lib then return nil, REASON.unavailable end
	local at, width, height, depth, colour, interlace = 9, nil, nil, nil, nil, nil
	local palette, data = nil, {}
	while at + 8 <= #bytes do
		local length, kind = u32(bytes, at), bytes:sub(at + 4, at + 7)
		local body = bytes:sub(at + 8, at + 7 + length)
		if #body ~= length then return nil, REASON.unreadable end
		if kind == "IHDR" then
			if length ~= 13 then return nil, REASON.unreadable end
			width, height = u32(body, 1), u32(body, 5)
			depth, colour, interlace = body:byte(9), body:byte(10), body:byte(13)
		elseif kind == "PLTE" then
			palette = body
		elseif kind == "IDAT" then
			data[#data + 1] = body
		elseif kind == "IEND" then
			break
		end
		at = at + 12 + length
	end
	local channels = colour and CHANNELS[colour]
	if not width or width < 1 or height < 1 or width * height > max_pixels or depth ~= 8 or not channels
		or interlace ~= 0 or (colour == 3 and not palette) then
		return nil, REASON.unreadable
	end
	local stride = width * channels
	local expected = height * (stride + 1)
	local compressed = table.concat(data)
	local out = ffi.new("unsigned char[?]", expected)
	local out_len = ffi.new("unsigned long[1]", expected)
	if lib.uncompress(out, out_len, compressed, #compressed) ~= Z_OK or tonumber(out_len[0]) ~= expected then
		return nil, REASON.unreadable
	end
	local previous = ffi.new("unsigned char[?]", stride)
	local row = ffi.new("unsigned char[?]", stride)
	local pixels, n = {}, 0
	for y = 0, height - 1 do
		local base = y * (stride + 1)
		local filter = out[base]
		for i = 0, stride - 1 do
			local x = out[base + 1 + i]
			local a = i >= channels and row[i - channels] or 0
			local b = previous[i]
			local c = i >= channels and previous[i - channels] or 0
			if filter == 1 then x = x + a
			elseif filter == 2 then x = x + b
			elseif filter == 3 then x = x + math.floor((a + b) / 2)
			elseif filter == 4 then x = x + paeth(a, b, c)
			elseif filter ~= 0 then return nil, REASON.unreadable end
			row[i] = x % 256
		end
		for px = 0, width - 1 do
			local i = px * channels
			local gray
			if colour == 0 or colour == 4 then
				gray = row[i]
			elseif colour == 3 then
				local entry = row[i] * 3
				if entry + 3 > #palette then return nil, REASON.unreadable end
				gray = Matcher.gray(palette:byte(entry + 1), palette:byte(entry + 2), palette:byte(entry + 3))
			else
				gray = Matcher.gray(row[i], row[i + 1], row[i + 2])
			end
			n = n + 1
			pixels[n] = gray
		end
		previous, row = row, previous
	end
	return { width = width, height = height, pixels = pixels }
end

--- One PNG chunk with its CRC.
local function chunk(lib, kind, body)
	local crc = tonumber(lib.crc32(0, kind .. body, #kind + #body))
	return be32(#body) .. kind .. body .. be32(crc)
end

--- Encodes a grayscale image as an 8-bit gray PNG.
--- @param image table { width, height, pixels }
--- @return string|nil bytes
--- @return string|nil reason
function M.encode_gray(image)
	assert(type(image) == "table" and type(image.pixels) == "table", "png_codec.encode_gray needs an image")
	local lib, ffi = zlib()
	if not lib then return nil, REASON.unavailable end
	local width, height = image.width, image.height
	local raw_len = height * (width + 1)
	local raw = ffi.new("unsigned char[?]", raw_len)
	for y = 0, height - 1 do
		local base = y * (width + 1)
		raw[base] = 0
		for x = 0, width - 1 do raw[base + 1 + x] = image.pixels[y * width + x + 1] end
	end
	local bound = tonumber(lib.compressBound(raw_len))
	local out = ffi.new("unsigned char[?]", bound)
	local out_len = ffi.new("unsigned long[1]", bound)
	if lib.compress2(out, out_len, raw, raw_len, Z_BEST_SPEED) ~= Z_OK then return nil, REASON.refused end
	local header = be32(width) .. be32(height) .. string.char(8, 0, 0, 0, 0)
	return SIGNATURE .. chunk(lib, "IHDR", header) .. chunk(lib, "IDAT", ffi.string(out, out_len[0]))
		.. chunk(lib, "IEND", "")
end

return M
