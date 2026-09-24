-- QOI, the "Quite OK Image" format.
--
-- A fourteen byte header, then a stream of one and two byte ops over a pixel that
-- carries from one op to the next: either a whole colour, a difference from the
-- last one, a lookup in a sixty-four entry index, or a run of the pixel just seen.
-- It is small enough to carry here, in Lua, and being here is what lets this
-- package write it — stb does not know the format at all.
local ffi = require("ffi")
local bit = require("bit")
local pixels = require("image.pixels")

---@class image.formats.Qoi: image.Codec
local Qoi = {}

Qoi.name = "qoi"

---@type image.FormatSpec[]
Qoi.formats = {
	{ name = "QOI", extensions = { "qoi" }, magic = { "qoif" }, write = "qoi" },
}

local HEADER = 14
-- Seven zero bytes and a one close every stream.
local END_MARKER = "\0\0\0\0\0\0\0\1"

local OP_RGB = 0xFE
local OP_RGBA = 0xFF

local OP_INDEX = 0
local OP_DIFF = 1
local OP_LUMA = 2
local OP_RUN = 3

-- The index slot a pixel belongs in.
---@param r number
---@param g number
---@param b number
---@param a number
---@return number
local function hash(r, g, b, a)
	return (r * 3 + g * 5 + b * 7 + a * 11) % 64
end

--- A run op carries up to sixty-two repeats of the pixel before it.
local MAX_RUN = 62

---@param data string
---@return number? width
---@return number? height
---@return number? channels
---@return string? err
local function readHeader(data)
	if #data < HEADER + 8 then
		return nil, nil, nil, "Not a QOI image: it is too short to hold a header"
	end

	if string.sub(data, 1, 4) ~= "qoif" then
		return nil, nil, nil, "Not a QOI image: the header does not start with qoif"
	end

	local a, b, c, d = string.byte(data, 5, 8)
	local width = a * 16777216 + b * 65536 + c * 256 + d
	a, b, c, d = string.byte(data, 9, 12)
	local height = a * 16777216 + b * 65536 + c * 256 + d
	local channels = string.byte(data, 13)

	if width == 0 or height == 0 then
		return nil, nil, nil, "Damaged QOI data: the header claims an empty image"
	end

	if channels ~= 3 and channels ~= 4 then
		return nil, nil, nil, "Damaged QOI data: the header claims " .. tostring(channels) .. " channels"
	end

	-- Every op spells out at least one pixel, and a run op at most sixty-two, so a
	-- stream cannot hold more pixels than this however well it compresses.
	if width * height > MAX_RUN * (#data - HEADER - 8) then
		return nil, nil, nil, "Damaged QOI data: the header claims more pixels than the stream holds"
	end

	return width, height, channels
end

---@param data string
---@param options image.DecodeOptions?
---@return image.Decoded? decoded
---@return string? err
function Qoi.decode(data, options)
	local width, height, channels, err = readHeader(data)

	if width == nil or height == nil or channels == nil then
		return nil, err
	end

	local count = width * height
	local buffer = ffi.new("uint8_t[?]", count * channels)

	-- The index starts out empty: every slot is a transparent black pixel.
	local index = ffi.new("uint8_t[64][4]")
	local r, g, b, a = 0, 0, 0, 255

	-- One based, into the file. The eight bytes that close the stream are not ops,
	-- so a stream that runs out of them before it runs out of pixels is damaged
	-- rather than full of transparent ones.
	local endOfOps = #data
	if string.sub(data, #data - 7) == END_MARKER then
		endOfOps = #data - 8
	end

	local position = HEADER + 1
	local run = 0

	for pixel = 0, count - 1 do
		if run > 0 then
			run = run - 1
		else
			local op = string.byte(data, position)

			if op == nil or position > endOfOps then
				return nil, "Damaged QOI data: the stream ends before the image does"
			end

			position = position + 1

			if op == OP_RGB or op == OP_RGBA then
				local size = op == OP_RGB and 3 or 4

				if position + size - 1 > endOfOps then
					return nil, "Damaged QOI data: the stream ends inside a pixel"
				end

				r, g, b = string.byte(data, position, position + 2)
				if op == OP_RGBA then
					a = string.byte(data, position + 3)
				end

				position = position + size
			else
				local kind = bit.rshift(op, 6)

				if kind == OP_INDEX then
					local slot = index[bit.band(op, 0x3F)]
					r, g, b, a = slot[0], slot[1], slot[2], slot[3]
				elseif kind == OP_DIFF then
					-- Two bits per channel, biased by two.
					r = bit.band(r + bit.band(bit.rshift(op, 4), 3) - 2, 0xFF)
					g = bit.band(g + bit.band(bit.rshift(op, 2), 3) - 2, 0xFF)
					b = bit.band(b + bit.band(op, 3) - 2, 0xFF)
				elseif kind == OP_LUMA then
					-- The green difference, then red and blue against it.
					local second = string.byte(data, position)

					if second == nil or position > endOfOps then
						return nil, "Damaged QOI data: the stream ends inside a pixel"
					end

					position = position + 1

					local dg = bit.band(op, 0x3F) - 32
					local dr = bit.band(bit.rshift(second, 4), 0x0F) - 8 + dg
					local db = bit.band(second, 0x0F) - 8 + dg

					r = bit.band(r + dr, 0xFF)
					g = bit.band(g + dg, 0xFF)
					b = bit.band(b + db, 0xFF)
				else
					run = bit.band(op, 0x3F)
				end
			end

			-- Every pixel the stream spells out becomes an index entry, which is
			-- what a later index op looks up.
			local slot = index[hash(r, g, b, a)]
			slot[0], slot[1], slot[2], slot[3] = r, g, b, a
		end

		local offset = pixel * channels
		buffer[offset], buffer[offset + 1], buffer[offset + 2] = r, g, b

		if channels == 4 then
			buffer[offset + 3] = a
		end
	end

	local wanted = options ~= nil and options.channels or channels

	if wanted ~= channels then
		buffer = pixels.convert(buffer, count, channels, wanted)
	end

	return {
		width = width,
		height = height,
		channels = wanted,
		fileChannels = channels,
		pixels = buffer,
	}
end

---@param data string
---@return image.Info? info
---@return string? err
function Qoi.probe(data)
	local width, height, channels, err = readHeader(data)

	if width == nil or height == nil or channels == nil then
		return nil, err
	end

	return {
		width = width,
		height = height,
		channels = channels,
		bits = 8,
	}
end

---@param buffer ffi.cdata* # uint8_t*
---@param width number
---@param height number
---@param channels number
---@return string? encoded
---@return string? err
function Qoi.encode(buffer, width, height, channels)
	local count = width * height

	-- The worst case is one RGBA op per pixel, which is five bytes.
	local out = ffi.new("uint8_t[?]", HEADER + count * 5 + 8)
	local position = 0

	local header = string.char(
		0x71, 0x6F, 0x69, 0x66, -- "qoif"
		bit.band(bit.rshift(width, 24), 0xFF), bit.band(bit.rshift(width, 16), 0xFF),
		bit.band(bit.rshift(width, 8), 0xFF), bit.band(width, 0xFF),
		bit.band(bit.rshift(height, 24), 0xFF), bit.band(bit.rshift(height, 16), 0xFF),
		bit.band(bit.rshift(height, 8), 0xFF), bit.band(height, 0xFF),
		channels == 4 and 4 or 3,
		0 -- sRGB
	)

	ffi.copy(out, header, HEADER)
	position = HEADER

	local index = ffi.new("uint8_t[64][4]")
	local r, g, b, a = 0, 0, 0, 255
	local run = 0

	for pixel = 0, count - 1 do
		local offset = pixel * channels
		local pr, pg, pb = buffer[offset], buffer[offset + 1], buffer[offset + 2]
		local pa = channels == 4 and buffer[offset + 3] or 255

		if pr == r and pg == g and pb == b and pa == a then
			run = run + 1

			-- A run op has six bits of length, and the last pixel of the image
			-- has to be flushed either way.
			if run == MAX_RUN or pixel == count - 1 then
				out[position] = bit.bor(bit.lshift(OP_RUN, 6), run - 1)
				position = position + 1
				run = 0
			end
		else
			if run > 0 then
				out[position] = bit.bor(bit.lshift(OP_RUN, 6), run - 1)
				position = position + 1
				run = 0
			end

			local slot = hash(pr, pg, pb, pa)
			local entry = index[slot]

			if entry[0] == pr and entry[1] == pg and entry[2] == pb and entry[3] == pa then
				out[position] = bit.bor(bit.lshift(OP_INDEX, 6), slot)
				position = position + 1
			else
				entry[0], entry[1], entry[2], entry[3] = pr, pg, pb, pa

				local dr, dg, db = pr - r, pg - g, pb - b
				local drdg, dbdg = dr - dg, db - dg

				if pa == a and dr >= -2 and dr <= 1 and dg >= -2 and dg <= 1 and db >= -2 and db <= 1 then
					out[position] = bit.bor(
						bit.lshift(OP_DIFF, 6),
						bit.lshift(bit.band(dr + 2, 3), 4),
						bit.lshift(bit.band(dg + 2, 3), 2),
						bit.band(db + 2, 3)
					)
					position = position + 1
				elseif pa == a and dg >= -32 and dg <= 31 and drdg >= -8 and drdg <= 7 and dbdg >= -8 and dbdg <= 7 then
					out[position] = bit.bor(bit.lshift(OP_LUMA, 6), bit.band(dg + 32, 0x3F))
					out[position + 1] = bit.bor(bit.lshift(bit.band(drdg + 8, 0x0F), 4), bit.band(dbdg + 8, 0x0F))
					position = position + 2
				elseif pa == a then
					out[position], out[position + 1], out[position + 2], out[position + 3] = OP_RGB, pr, pg, pb
					position = position + 4
				else
					out[position], out[position + 1], out[position + 2], out[position + 3], out[position + 4] =
						OP_RGBA, pr, pg, pb, pa
					position = position + 5
				end
			end
		end

		r, g, b, a = pr, pg, pb, pa
	end

	ffi.copy(out + position, END_MARKER, 8)

	return ffi.string(out, position + 8)
end

return Qoi
