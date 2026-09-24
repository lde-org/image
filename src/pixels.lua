-- The pixel buffer arithmetic the codecs and the Image class share.
--
-- Everything here works on raw 8-bit buffers: a width, a height, and one to four
-- bytes per pixel. Fewer than four channels is not a different colour model, just a
-- shorter one — one channel is grey, two is grey with alpha, three is colour — so
-- reading a pixel always produces r, g, b, a with whatever the buffer does not hold
-- filled in, and writing one keeps the channels the buffer has.
local ffi = require("ffi")

local pixels = {}

--- The grey a colour amounts to, the same weighting the codecs use.
---@param r number
---@param g number
---@param b number
---@return number
local function luminance(r, g, b)
	return math.floor((r * 77 + g * 150 + b * 29) / 256)
end

--- Reads one pixel into four values, filling in what the buffer cannot say.
---@param buffer ffi.cdata* # uint8_t*
---@param offset number
---@param channels number
---@return number r
---@return number g
---@return number b
---@return number a
function pixels.read(buffer, offset, channels)
	if channels <= 2 then
		local grey = buffer[offset]

		return grey, grey, grey, channels == 2 and buffer[offset + 1] or 255
	end

	local r, g, b = buffer[offset], buffer[offset + 1], buffer[offset + 2]

	return r, g, b, channels == 4 and buffer[offset + 3] or 255
end

--- Writes one pixel, keeping only the channels the buffer holds.
---@param buffer ffi.cdata* # uint8_t*
---@param offset number
---@param channels number
---@param r number
---@param g number
---@param b number
---@param a number
function pixels.write(buffer, offset, channels, r, g, b, a)
	if channels <= 2 then
		buffer[offset] = luminance(r, g, b)

		if channels == 2 then
			buffer[offset + 1] = a
		end

		return
	end

	buffer[offset], buffer[offset + 1], buffer[offset + 2] = r, g, b

	if channels == 4 then
		buffer[offset + 3] = a
	end
end

--- Converts a buffer to another channel count, as a new buffer.
---@param buffer ffi.cdata* # uint8_t*
---@param count number # pixels in the buffer
---@param from number # channels the buffer holds
---@param to number # channels to write
---@return ffi.cdata* # uint8_t*, collected by Lua
function pixels.convert(buffer, count, from, to)
	assert(to >= 1 and to <= 4, "An image holds between 1 and 4 channels")
	assert(from >= 1 and from <= 4, "An image holds between 1 and 4 channels")

	if from == to then
		local copy = ffi.new("uint8_t[?]", count * to)
		ffi.copy(copy, buffer, count * to)

		return copy
	end

	local out = ffi.new("uint8_t[?]", count * to)

	for index = 0, count - 1 do
		local r, g, b, a = pixels.read(buffer, index * from, from)

		pixels.write(out, index * to, to, r, g, b, a)
	end

	return out
end

--- Fills a buffer with one colour, given as r, g, b, a and stored the way the
--- buffer's channel count allows.
---@param buffer ffi.cdata* # uint8_t*
---@param count number
---@param channels number
---@param r number
---@param g number
---@param b number
---@param a number?
function pixels.fill(buffer, count, channels, r, g, b, a)
	for index = 0, count - 1 do
		pixels.write(buffer, index * channels, channels, r, g, b, a or 255)
	end
end

--- Flips a buffer vertically, which is what a graphics API reading its textures
--- bottom row first wants.
---@param buffer ffi.cdata* # uint8_t*
---@param width number
---@param height number
---@param channels number
function pixels.flip(buffer, width, height, channels)
	local stride = width * channels
	local row = ffi.new("uint8_t[?]", stride)

	for y = 0, math.floor(height / 2) - 1 do
		local top = buffer + y * stride
		local bottom = buffer + (height - 1 - y) * stride

		ffi.copy(row, top, stride)
		ffi.copy(top, bottom, stride)
		ffi.copy(bottom, row, stride)
	end
end

return pixels
