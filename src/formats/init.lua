-- The formats this package reads and writes, and the codecs that do it.
--
-- A codec is a shape rather than a base class: each module returns a table with the
-- fields below, and a format names the codec that reads it. stb carries everything
-- the C library knows; QOI and netpbm are small enough to live in Lua, which is
-- also why netpbm can be written here at all — stb only ever reads it.
local Stb = require("image.formats.stb")
local Qoi = require("image.formats.qoi")
local Ppm = require("image.formats.ppm")

---@class image.Codec
---@field name string
---@field formats image.FormatSpec[]
---@field decode fun(data: string, options: image.DecodeOptions?): image.Decoded?, string?
---@field decodeFrames? fun(data: string, options: image.DecodeOptions?): image.Decoded[]?, string?
---@field probe? fun(data: string): image.Info?, string?
---@field encode? fun(pixels: ffi.cdata*, width: number, height: number, channels: number, format: image.Format, options: image.EncodeOptions): string?, string?

--- What a codec declares about one format. The registry is what attaches the codec
--- itself, so a codec does not have to name itself in its own list.
---@class image.FormatSpec
---@field name string # what image.identify reports, and what encode takes
---@field extensions string[] # what a save goes by when it has no format of its own
---@field magic string[]? # the prefixes a file of this format starts with
---@field write string? # what the encoder calls it, when it can be written
---@field channels number[]? # the channel counts the encoder accepts, when it is picky

---@class image.Format: image.FormatSpec
---@field codec image.Codec

---@class image.Decoded
---@field format image.Format?
---@field width number
---@field height number
---@field channels number # channels the pixel buffer holds
---@field fileChannels number # channels the file held, before any narrowing
---@field pixels ffi.cdata* # uint8_t*
---@field handle ffi.cdata*? # the native handle owning the pixels, when there is one
---@field borrowed boolean? # true when the handle belongs to something else, as a frame's does
---@field delay number? # milliseconds to show this frame, for an animation

---@class image.Info
---@field format image.Format?
---@field width number
---@field height number
---@field channels number
---@field bits number # 8 or 16, the width of the file's samples

--- The codecs in the order detection walks them. stb is last because it is the one
--- that will try anything, so a format another codec knows wins the argument.
---@type image.Codec[]
local codecs = { Qoi, Ppm, Stb }

local Formats = {}

--- Every format there is, by name, and by the extension a file would carry.
---@type table<string, image.Format>
Formats.byName = {}

---@type table<string, image.Format>
Formats.byExtension = {}

---@type image.Format[]
Formats.list = {}

for _, codec in ipairs(codecs) do
	for _, spec in ipairs(codec.formats) do
		assert(Formats.byName[spec.name] == nil, "two codecs claim the " .. spec.name .. " format")

		---@cast spec image.Format
		local format = spec

		format.codec = codec
		Formats.byName[format.name] = format
		Formats.list[#Formats.list + 1] = format

		for _, extension in ipairs(format.extensions) do
			assert(Formats.byExtension[extension] == nil, "two formats claim the ." .. extension .. " extension")
			Formats.byExtension[extension] = format
		end
	end
end

--- What a file of these bytes is, by its header alone. Formats without a signature,
--- which is what TGA is, never come back from here.
---@param data string
---@return image.Format? format
function Formats.detect(data)
	for _, format in ipairs(Formats.list) do
		local magic = format.magic

		if magic ~= nil then
			for _, prefix in ipairs(magic) do
				if string.sub(data, 1, #prefix) == prefix then
					return format
				end
			end
		end
	end

	return nil
end

--- The extension of a path: what follows its last dot, in lower case.
---
--- Walked backwards one byte at a time rather than matched, which keeps the two
--- stops that matter — the last dot, and the separator that ends the file name —
--- from costing a pattern and a capture on a path that is looked at on every load
--- and every save.
---@param path string
---@return string? extension
function Formats.extension(path)
	local dot = nil

	for index = #path, 1, -1 do
		local byte = string.byte(path, index)

		if byte == 0x2E then -- "."
			dot = index
			break
		end

		if byte == 0x2F or byte == 0x5C then -- "/" or "", which ends the name
			break
		end
	end

	-- A dot at the very end names nothing, and a name that is only a dot is a
	-- hidden file rather than one with an extension.
	if dot == nil or dot == #path or dot == 1 then
		return nil
	end

	return string.lower(string.sub(path, dot + 1))
end

--- The format a file name suggests, taken from the extension.
---@param path string
---@return image.Format? format
function Formats.fromPath(path)
	local extension = Formats.extension(path)

	if extension == nil then
		return nil
	end

	return Formats.byExtension[extension]
end

--- Refuses a decode that was asked for a channel count no image can have.
---@param options image.DecodeOptions?
---@return string? err
local function checkOptions(options)
	local channels = options ~= nil and options.channels or nil

	if channels ~= nil and (channels < 1 or channels > 4) then
		return string.format("An image holds between 1 and 4 channels, and %s were asked for", tostring(channels))
	end

	return nil
end

--- The codec and format to read some bytes with.
---@param data string
---@param hint image.Format? # the format to assume when the bytes say nothing
---@return image.Format? format
---@return image.Codec codec
local function pick(data, hint)
	local format = Formats.detect(data) or hint

	-- Nothing recognized the header, and stb is still worth a try: it holds a
	-- heuristic for TGA, which has no signature to go by.
	return format, format ~= nil and format.codec or Stb
end

--- Decodes the first frame of an image.
---@param data string
---@param options image.DecodeOptions?
---@param hint image.Format? # the format to assume when the bytes say nothing
---@return image.Decoded? decoded
---@return string? err
function Formats.decode(data, options, hint)
	local invalid = checkOptions(options)

	if invalid ~= nil then
		return nil, invalid
	end

	local format, codec = pick(data, hint)
	local decoded, err = codec.decode(data, options)

	if decoded == nil then
		return nil, err
	end

	decoded.format = format

	return decoded
end

--- Decodes every frame of an animation, and the one frame of anything else, as a
--- list in playback order.
---@param data string
---@param options image.DecodeOptions?
---@param hint image.Format? # the format to assume when the bytes say nothing
---@return image.Decoded[]? frames
---@return string? err
function Formats.decodeFrames(data, options, hint)
	local invalid = checkOptions(options)

	if invalid ~= nil then
		return nil, invalid
	end

	local format, codec = pick(data, hint)

	if codec.decodeFrames == nil then
		-- A still is an animation of one frame, from the caller's side.
		local decoded, err = codec.decode(data, options)

		if decoded == nil then
			return nil, err
		end

		decoded.format = format

		return { decoded }
	end

	local frames, err = codec.decodeFrames(data, options)

	if frames == nil then
		return nil, err
	end

	for _, frame in ipairs(frames) do
		frame.format = format
	end

	return frames
end

--- What a file states about itself, read from its header rather than its pixels.
--- The codecs that carry their own reader report it; for everything else stb reads
--- the header without decoding, which is what it is for.
---@param data string
---@param hint image.Format?
---@return image.Info? info
---@return string? err
function Formats.probe(data, hint)
	local format, codec = pick(data, hint)
	local info, err

	if codec.probe ~= nil then
		info, err = codec.probe(data)
	else
		info, err = Stb.probe(data)
	end

	if info == nil then
		return nil, err
	end

	info.format = format

	return info
end

--- Encodes pixels as one of the formats that can be written.
---@param pixels ffi.cdata* # uint8_t*
---@param width number
---@param height number
---@param channels number
---@param format image.Format
---@param options image.EncodeOptions
---@return string? encoded
---@return string? err
function Formats.encode(pixels, width, height, channels, format, options)
	if pixels == nil then
		return nil, "The image has no pixels: it was closed, or never decoded"
	end

	if format.write == nil then
		local writable = {}

		for _, candidate in ipairs(Formats.list) do
			if candidate.write ~= nil then
				writable[#writable + 1] = string.lower(candidate.name)
			end
		end

		return nil, format.name .. " cannot be written. This package writes " .. table.concat(writable, ", ") .. "."
	end

	if format.channels ~= nil then
		local allowed = false

		for _, count in ipairs(format.channels) do
			allowed = allowed or count == channels
		end

		if not allowed then
			local counts = {}
			for _, count in ipairs(format.channels) do
				counts[#counts + 1] = tostring(count)
			end

			return nil, string.format(
				"A %s holds %s channel pixels, and this image has %d. Convert it first.",
				format.name, table.concat(counts, " or "), channels)
		end
	end

	return format.codec.encode(pixels, width, height, channels, format, options)
end

return Formats
