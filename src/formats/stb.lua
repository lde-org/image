-- Everything stb_image reads, and the four of those it can write too.
--
-- stb reports the channels a file held and the ones it handed back separately, so a
-- decode that asks for a different count narrows or widens without this module
-- doing the arithmetic.
local native = require("image.native")

---@class image.formats.Stb: image.Codec
local Stb = {}

Stb.name = "stb"

--- The formats stb reads. HDR is narrowed to eight bit samples on the way out,
--- which is what its loader does; PIC and PSD are read as their composited view.
--- A format without a magic number is only ever found by its extension, which is
--- TGA's problem: it has no signature to look for.
---@type image.FormatSpec[]
Stb.formats = {
	{ name = "PNG", extensions = { "png" }, magic = { "\137PNG\r\n\26\n" }, write = "png" },
	{ name = "JPEG", extensions = { "jpg", "jpeg", "jpe", "jfif" }, magic = { "\255\216\255" }, write = "jpg" },
	{ name = "TGA", extensions = { "tga", "targa", "icb", "vda", "vst" }, write = "tga" },
	-- stb writes a 24 bit bitmap for anything that is not four channels, which
	-- would read a narrower buffer as though it were colour.
	{ name = "BMP", extensions = { "bmp", "dib" }, magic = { "BM" }, write = "bmp", channels = { 3, 4 } },
	{ name = "GIF", extensions = { "gif" }, magic = { "GIF87a", "GIF89a" } },
	{ name = "PSD", extensions = { "psd" }, magic = { "8BPS" } },
	{ name = "HDR", extensions = { "hdr" }, magic = { "#?RADIANCE", "#?RGBE" } },
	{ name = "PIC", extensions = { "pic" }, magic = { "\83\128\246\52" } },
}

---@param data string
---@param options image.DecodeOptions?
---@return image.Decoded? decoded
---@return string? err
function Stb.decode(data, options)
	local handle, err = native.decode(data, options and options.channels)

	if handle == nil then
		return nil, err
	end

	local decoded = native.describe(handle)

	return {
		width = decoded.width,
		height = decoded.height,
		channels = decoded.pixelChannels,
		fileChannels = decoded.channels,
		pixels = decoded.pixels,
		handle = handle,
	}
end

---@param data string
---@param options image.DecodeOptions?
---@return image.Decoded[]? frames
---@return string? err
function Stb.decodeFrames(data, options)
	local handle, err = native.decodeFrames(data, options and options.channels)

	if handle == nil then
		return nil, err
	end

	local decoded = native.describe(handle)

	if decoded.frames < 1 or decoded.width <= 0 or decoded.height <= 0 then
		return nil, "The file decoded to no frames at all"
	end

	local stride = decoded.width * decoded.height * decoded.pixelChannels
	local animated = decoded.frames > 1

	---@type image.Decoded[]
	local frames = {}

	for index = 0, decoded.frames - 1 do
		frames[#frames + 1] = {
			width = decoded.width,
			height = decoded.height,
			channels = decoded.pixelChannels,
			fileChannels = decoded.channels,
			-- Every frame sits in the one buffer stb allocated, one after another.
			pixels = decoded.pixels + index * stride,
			handle = handle,
			-- The animation releases the buffer, not any one of its frames.
			borrowed = true,
			delay = animated and native.frameDelay(handle, index) or nil,
		}
	end

	return frames
end

---@param data string
---@return image.Info? info
---@return string? err
function Stb.probe(data)
	local info, err = native.probe(data)

	if info == nil then
		return nil, err
	end

	return {
		width = info.width,
		height = info.height,
		channels = info.channels,
		bits = info.bits,
	}
end

---@param pixels ffi.cdata* # uint8_t*
---@param width number
---@param height number
---@param channels number
---@param format image.Format
---@param options image.EncodeOptions
---@return string? encoded
---@return string? err
function Stb.encode(pixels, width, height, channels, format, options)
	return native.encode(pixels, {
		format = native.writeFormats[format.write],
		width = width,
		height = height,
		channels = channels,
		quality = options.quality,
		compression = options.compression,
		rle = options.rle,
	})
end

return Stb
