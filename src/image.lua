-- The image itself: a pixel buffer, the shape of it, and the two things there are
-- to do with one — read and write it a pixel at a time, and hand it to a codec to
-- be written out.
--
-- Pixels are a raw 8-bit buffer, one to four bytes per pixel in r, g, b, a order,
-- and nothing here moves them through a Lua table: a canvas worth of pixels is far
-- too much for that, which is why the buffer is an ffi cdata and the accessors
-- copy single pixels only.
local ffi = require("ffi")
local Formats = require("image.formats")
local native = require("image.native")
local pixels = require("image.pixels")

--- What a decode may be asked for.
---@class image.DecodeOptions
---@field channels number? # 1 to 4, decode into that many channels
---@field flip boolean? # turn the image upside down while decoding

--- What an encode may be asked for. A value outside the range a format takes is
--- clamped by the encoder rather than refused.
---@class image.EncodeOptions
---@field format string? # the format to write, when the caller has a say
---@field quality number? # JPEG, 1 to 100, ninety by default
---@field compression number? # PNG zlib level, 0 to 9, eight by default
---@field rle boolean? # TGA run length encoding, on by default

---@class image.Image
---@field width number
---@field height number
---@field channels number # 1 grey, 2 grey and alpha, 3 colour, 4 colour and alpha
---@field fileChannels number? # the channels the file held, when it came from one
---@field format image.Format? # what it was decoded from
---@field delay number? # milliseconds to show it, for a frame of an animation
---@field pixels ffi.cdata* # uint8_t*, width * height * channels bytes
---@field handle ffi.cdata*? # the native handle the pixels live in, when there is one
---@field private owned boolean # whether closing this image is what releases it
local Image = {}
Image.__index = Image

--- The class an image of several frames comes back in, defined below next to the
--- images it holds; a local has to be declared before the functions that name it.
---@class image.Animation
---@field format image.Format?
---@field width number
---@field height number
---@field frames image.Image[] # in playback order, each carrying its delay in milliseconds
---@field handle ffi.cdata*?
local Animation

--- An image with a buffer of its own, or one borrowed from a caller who keeps it
--- alive.
---@param width number
---@param height number
---@param channels number? # 1 to 4, four by default
---@param pixels ffi.cdata*? # uint8_t*, borrowed when given
---@return image.Image
function Image.new(width, height, channels, pixels)
	assert(width > 0 and height > 0, "An image needs a width and a height")
	assert(channels == nil or (channels >= 1 and channels <= 4), "An image holds between 1 and 4 channels")

	channels = channels or 4

	return setmetatable({
		width = width,
		height = height,
		channels = channels,
		pixels = pixels or ffi.new("uint8_t[?]", width * height * channels),
		owned = false,
	}, Image)
end

---@param decoded image.Decoded
---@return image.Image
function Image.fromDecoded(decoded)
	return setmetatable({
		width = decoded.width,
		height = decoded.height,
		channels = decoded.channels,
		fileChannels = decoded.fileChannels,
		format = decoded.format,
		delay = decoded.delay,
		pixels = decoded.pixels,
		handle = decoded.handle,
		-- A frame of an animation borrows the buffer its animation owns.
		owned = decoded.handle ~= nil and not decoded.borrowed,
	}, Image)
end

--- The image a decoded record makes, flipped when the caller asked for that.
---@param decoded image.Decoded
---@param options image.DecodeOptions?
---@return image.Image
local function makeImage(decoded, options)
	local result = Image.fromDecoded(decoded)

	if options ~= nil and options.flip then
		result:flip()
	end

	return result
end

---@param path string
---@return string? data
---@return string? err
local function readFile(path)
	local file, err = io.open(path, "rb")

	if file == nil then
		return nil, "Failed to open " .. path .. ": " .. tostring(err)
	end

	local data = file:read("*a")
	file:close()

	if data == nil or data == "" then
		return nil, "Failed to read " .. path
	end

	return data
end

--- Decodes the first frame of an image, from the bytes of one.
---@param data string
---@param options image.DecodeOptions?
---@return image.Image? image
---@return string? err
function Image.decode(data, options)
	local decoded, err = Formats.decode(data, options)

	if decoded == nil then
		return nil, err
	end

	return makeImage(decoded, options)
end

--- Reads a file and decodes its first frame. The extension is only a hint for what
--- the bytes already look like: a signature wins over it, and it is what names the
--- format of one that has none.
---@param path string
---@param options image.DecodeOptions?
---@return image.Image? image
---@return string? err
function Image.load(path, options)
	local data, err = readFile(path)

	if data == nil then
		return nil, err
	end

	local decoded, decodeErr = Formats.decode(data, options, Formats.fromPath(path))

	if decoded == nil then
		return nil, decodeErr
	end

	return makeImage(decoded, options)
end

--- Decodes every frame of an animation, and the one frame of anything else.
---@param data string
---@param options image.DecodeOptions?
---@param hint image.Format? # the format to assume when the bytes say nothing
---@return image.Animation? animation
---@return string? err
function Image.decodeFrames(data, options, hint)
	local frames, err = Formats.decodeFrames(data, options, hint)

	if frames == nil then
		return nil, err
	end

	if #frames == 0 then
		return nil, "The file decoded to no frames at all"
	end

	local images = {}

	for _, frame in ipairs(frames) do
		images[#images + 1] = makeImage(frame, options)
	end

	local first = frames[1]

	return Animation.new(first.format, first.width, first.height, images, first.handle), nil
end

--- Reads a file and decodes every frame of it.
---@param path string
---@param options image.DecodeOptions?
---@return image.Animation? animation
---@return string? err
function Image.loadFrames(path, options)
	local data, err = readFile(path)

	if data == nil then
		return nil, err
	end

	return Image.decodeFrames(data, options, Formats.fromPath(path))
end

--- What a file states about itself, without decoding its pixels. The path is only
--- there to name a format that has no signature of its own, which is TGA.
---@param data string
---@param path string? # the file the bytes came from
---@return image.Info? info
---@return string? err
function Image.probe(data, path)
	return Formats.probe(data, path ~= nil and Formats.fromPath(path) or nil)
end

--- Whether the bytes look like something this package can decode.
---@param data string
---@return boolean
function Image.isValid(data)
	return Formats.detect(data) ~= nil or native.probe(data) ~= nil
end

--- The name of the format these bytes are, by their signature alone. A TGA has no
--- signature, so it never comes back from here, and a format that can only be told
--- apart by its extension is left to the file it came from.
---@param data string
---@return string? name
function Image.identify(data)
	local detected = Formats.detect(data)

	if detected == nil then
		return nil
	end

	return detected.name
end

--- Reads one pixel, at zero based coordinates, as r, g, b, a. A buffer with fewer
--- channels than four fills the rest in: grey reads the same in all three colours,
--- and a missing alpha reads as opaque.
---@param x number
---@param y number
---@return number r
---@return number g
---@return number b
---@return number a
function Image:getPixel(x, y)
	assert(x >= 0 and x < self.width, "X is outside the image")
	assert(y >= 0 and y < self.height, "Y is outside the image")

	return pixels.read(self.pixels, (y * self.width + x) * self.channels, self.channels)
end

--- Writes one pixel, keeping only the channels this image holds.
---@param x number
---@param y number
---@param r number
---@param g number
---@param b number
---@param a number?
function Image:setPixel(x, y, r, g, b, a)
	assert(x >= 0 and x < self.width, "X is outside the image")
	assert(y >= 0 and y < self.height, "Y is outside the image")

	pixels.write(self.pixels, (y * self.width + x) * self.channels, self.channels, r, g, b, a or 255)
end

--- Fills the whole image with one colour, as setPixel would store it.
---@param r number
---@param g number
---@param b number
---@param a number?
---@return image.Image self
function Image:fill(r, g, b, a)
	pixels.fill(self.pixels, self.width * self.height, self.channels, r, g, b, a)

	return self
end

--- Turns the image upside down, in place.
---@return image.Image self
function Image:flip()
	pixels.flip(self.pixels, self.width, self.height, self.channels)

	return self
end

--- A copy of this image with a different number of channels.
---@param channels number # 1 to 4
---@return image.Image
function Image:convert(channels)
	assert(channels >= 1 and channels <= 4, "An image holds between 1 and 4 channels")

	return Image.new(self.width, self.height, channels,
		pixels.convert(self.pixels, self.width * self.height, self.channels, channels))
end

--- A copy of this image, pixels and all.
---@return image.Image
function Image:copy()
	return self:convert(self.channels)
end

--- The format to write, from what the caller named and what the file extension
--- suggests, in that order.
---@param name string? # a format name, like "png"
---@param path string? # the file it is going to, when there is one
---@return image.Format? format
---@return string? err
local function writeFormat(name, path)
	if name ~= nil then
		-- A format goes by its name, or by any of the extensions it is saved as,
		-- so "jpeg" and "jpg" are the same thing to write.
		local byName = Formats.byName[string.upper(name)] or Formats.byExtension[string.lower(name)]

		if byName == nil then
			return nil, "Unknown image format: " .. name
		end

		return byName
	end

	if path ~= nil then
		local byPath = Formats.fromPath(path)

		if byPath ~= nil then
			return byPath
		end

		local extension = Formats.extension(path)

		if extension ~= nil then
			return nil, "Unknown image format: ." .. extension
		end
	end

	-- Nothing to go by, so the format everything reads: PNG.
	return Formats.byName.PNG
end

--- Encodes the image, as PNG unless a format says otherwise.
---@param format string? # a format name, or nil to take options.format or PNG
---@param options image.EncodeOptions?
---@return string? encoded
---@return string? err
function Image:encode(format, options)
	options = options or {}

	local target, err = writeFormat(format or options.format, nil)

	if target == nil then
		return nil, err
	end

	return Formats.encode(self.pixels, self.width, self.height, self.channels, target, options)
end

--- Encodes the image and writes it to a file, in the format its extension names
--- unless options.format says otherwise.
---@param path string
---@param options image.EncodeOptions?
---@return boolean? written
---@return string? err
function Image:save(path, options)
	options = options or {}

	local target, err = writeFormat(options.format, path)

	if target == nil then
		return nil, err
	end

	---@cast target image.Format
	local encoded, encodeErr = Formats.encode(self.pixels, self.width, self.height, self.channels, target, options)

	if encoded == nil then
		return nil, encodeErr
	end

	local file, openErr = io.open(path, "wb")

	if file == nil then
		return nil, "Failed to open " .. path .. " for writing: " .. tostring(openErr)
	end

	-- An animation of one frame still writes one file.
	local written, writeErr = file:write(encoded)
	file:close()

	if written == nil then
		return nil, "Failed to write " .. path .. ": " .. tostring(writeErr)
	end

	return true
end

--- Releases the decoded pixels early, rather than leaving them to the collector,
--- and leaves the image empty: a closed image has no pixels to read.
---
--- Only the image that decoded them owns them. The frames of an animation share one
--- buffer, and it is the animation that lets it go, so closing a frame only drops
--- that frame.
function Image:close()
	if self.owned and self.handle ~= nil then
		native.release(self.handle)
	end

	self.handle = nil
	self.owned = false
	self.pixels = nil
end

--- The images a multi frame file holds, in playback order.
Animation = {}
Animation.__index = Animation

---@param format image.Format?
---@param width number
---@param height number
---@param frames image.Image[]
---@param handle ffi.cdata*?
---@return image.Animation
function Animation.new(format, width, height, frames, handle)
	return setmetatable({
		format = format,
		width = width,
		height = height,
		frames = frames,
		handle = handle,
	}, Animation)
end

--- The total time the animation runs for, in milliseconds.
---@return number
function Animation:duration()
	local total = 0

	for _, frame in ipairs(self.frames) do
		total = total + (frame.delay or 0)
	end

	return total
end

--- Releases the buffer every frame points into, which none of them can be used
--- after.
function Animation:close()
	if self.handle ~= nil then
		native.release(self.handle)
		self.handle = nil
	end

	for _, frame in ipairs(self.frames) do
		frame.pixels = nil
		frame.handle = nil
	end
end

Image.Animation = Animation

-- The names arisu-image used, kept so that a caller moving over does not have to
-- care which package it is holding.
Image.fromPath = Image.load
Image.fromData = Image.decode

return Image
