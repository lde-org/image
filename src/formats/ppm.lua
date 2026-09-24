-- The netpbm family: a short header of whitespace separated tokens, then samples
-- either as text or as bytes, and rows of bits for the bilevel pair.
--
-- stb reads the binary members, but nothing in it can write one, so the family
-- lives here instead. The one thing netpbm cannot carry is alpha, so a save drops
-- it, and the bilevel pair is read only: writing one would throw away most of an
-- image without saying so.
local ffi = require("ffi")
local bit = require("bit")
local pixels = require("image.pixels")

---@class image.formats.Ppm: image.Codec
local Ppm = {}

Ppm.name = "netpbm"

--- P3 and P6 are colour, P2 and P5 grey, and P1 and P4 bilevel.
---@type image.FormatSpec[]
Ppm.formats = {
	{ name = "PPM", extensions = { "ppm", "pnm" }, magic = { "P3", "P6" }, write = "ppm" },
	{ name = "PGM", extensions = { "pgm" }, magic = { "P2", "P5" }, write = "pgm" },
	{ name = "PBM", extensions = { "pbm" }, magic = { "P1", "P4" } },
}

--- The whitespace a header may separate its tokens with, which includes the
--- vertical tab and form feed the spec allows.
---@param byte number?
---@return boolean
local function isSpace(byte)
	return byte == 32 or (byte ~= nil and byte >= 9 and byte <= 13)
end

--- Reads one token, skipping the comments the header may hold anywhere.
---@param data string
---@param position number # one based
---@return string? token
---@return number position
local function token(data, position)
	while true do
		local byte = string.byte(data, position)

		if byte == nil then
			return nil, position
		elseif byte == 35 then -- "#" comments run to the end of the line
			local newline = string.find(data, "\n", position, true)
			position = newline == nil and #data + 1 or newline + 1
		elseif isSpace(byte) then
			position = position + 1
		else
			break
		end
	end

	local start = position

	while not isSpace(string.byte(data, position)) and string.byte(data, position) ~= nil do
		position = position + 1
	end

	return string.sub(data, start, position - 1), position
end

---@class image.formats.Ppm.Header
---@field magic string
---@field width number
---@field height number
---@field maxval number
---@field position number # one based, the first byte of the raster

---@param data string
---@return image.formats.Ppm.Header? header
---@return string? err
local function readHeader(data)
	local magic, position = token(data, 1)

	if magic == nil or #magic ~= 2 or string.sub(magic, 1, 1) ~= "P" or tonumber(string.sub(magic, 2)) == nil then
		return nil, "Not a netpbm image: the header does not start with P1 to P6"
	end

	local width, height
	width, position = token(data, position)
	height, position = token(data, position)

	width, height = tonumber(width or ""), tonumber(height or "")

	if width == nil or height == nil or width < 1 or height < 1 then
		return nil, "Damaged netpbm data: the header does not state a size"
	end

	-- The bilevel pair has no maximum value of its own.
	local maxval = 1

	if magic ~= "P1" and magic ~= "P4" then
		local value
		value, position = token(data, position)

		local stated = tonumber(value or "")

		if stated == nil or stated < 1 or stated > 65535 then
			return nil, "Damaged netpbm data: the header does not state a maximum value"
		end

		maxval = stated
	end

	-- Exactly one whitespace byte separates the header from the raster, though a
	-- writer on Windows may have left two.
	if string.byte(data, position) == 13 then
		position = position + 1
	end

	return {
		magic = magic,
		width = width,
		height = height,
		maxval = maxval,
		position = position + 1,
	}
end

--- A sample as the eight bit value netpbm's own maximum maps to.
---@param value number
---@param maxval number
---@return number
local function scale(value, maxval)
	if maxval == 255 then
		return value
	end

	return math.floor(value * 255 / maxval + 0.5)
end

---@param header image.formats.Ppm.Header
---@return number channels
---@return boolean text
---@return boolean bilevel
local function layout(header)
	local colour = header.magic == "P3" or header.magic == "P6"
	local text = header.magic == "P1" or header.magic == "P2" or header.magic == "P3"

	return colour and 3 or 1, text, header.magic == "P1" or header.magic == "P4"
end

---@param data string
---@param options image.DecodeOptions?
---@return image.Decoded? decoded
---@return string? err
function Ppm.decode(data, options)
	local header, err = readHeader(data)

	if header == nil then
		return nil, err
	end

	local count = header.width * header.height
	local channels, text, bilevel = layout(header)
	local buffer = ffi.new("uint8_t[?]", count * channels)

	-- One based, into the file.
	local position = header.position

	if bilevel and not text then
		-- Rows of bits, most significant first, each padded to a whole byte.
		local stride = math.floor((header.width + 7) / 8)

		if position + stride * header.height - 1 > #data then
			return nil, "Damaged netpbm data: the raster is shorter than the header claims"
		end

		for y = 0, header.height - 1 do
			for x = 0, header.width - 1 do
				local byte = string.byte(data, position + y * stride + math.floor(x / 8))
				-- A set bit is black, which is a zero sample.
				buffer[y * header.width + x] = bit.band(byte, bit.rshift(0x80, x % 8)) ~= 0 and 0 or 255
			end
		end
	elseif text then
		for index = 0, count * channels - 1 do
			local value
			value, position = token(data, position)

			if value == nil then
				return nil, "Damaged netpbm data: the raster is shorter than the header claims"
			end

			local sample = tonumber(value)

			if sample == nil then
				return nil, "Damaged netpbm data: the raster is not a list of numbers"
			end

			if bilevel then
				-- A one is black, which is a zero sample.
				buffer[index] = sample ~= 0 and 0 or 255
			else
				buffer[index] = scale(sample, header.maxval)
			end
		end
	else
		local wide = header.maxval > 255
		local size = wide and 2 or 1

		if position + count * channels * size - 1 > #data then
			return nil, "Damaged netpbm data: the raster is shorter than the header claims"
		end

		for index = 0, count * channels - 1 do
			local value = string.byte(data, position + index * size)

			if wide then
				value = value * 256 + string.byte(data, position + index * size + 1)
			end

			buffer[index] = scale(value, header.maxval)
		end
	end

	local wanted = options ~= nil and options.channels or channels

	if wanted ~= channels then
		buffer = pixels.convert(buffer, count, channels, wanted)
	end

	return {
		width = header.width,
		height = header.height,
		channels = wanted,
		fileChannels = channels,
		pixels = buffer,
	}
end

---@param data string
---@return image.Info? info
---@return string? err
function Ppm.probe(data)
	local header, err = readHeader(data)

	if header == nil then
		return nil, err
	end

	local channels = layout(header)

	return {
		width = header.width,
		height = header.height,
		channels = channels,
		bits = header.maxval > 255 and 16 or 8,
	}
end

---@param buffer ffi.cdata* # uint8_t*
---@param width number
---@param height number
---@param channels number
---@param format image.Format
---@return string? encoded
---@return string? err
function Ppm.encode(buffer, width, height, channels, format)
	local grey = format.write == "pgm"
	local count = width * height
	local wanted = grey and 1 or 3

	if channels ~= wanted then
		buffer = pixels.convert(buffer, count, channels, wanted)
	end

	local header = string.format("%s\n%d %d\n255\n", grey and "P5" or "P6", width, height)

	return header .. ffi.string(buffer, count * wanted)
end

return Ppm
