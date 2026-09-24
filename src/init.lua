-- An image library over stb_image, with the formats stb does not know — QOI, and
-- netpbm, which stb only reads — carried in Lua alongside it.
--
-- There is one image type, whatever the format was: pixels of eight bit samples,
-- one to four channels per pixel, plus what the file said about its shape.
--
--	local image = require("image")
--
--	local photo = assert(image.load("photo.png"))
--	photo:setPixel(0, 0, 255, 0, 0)
--	assert(photo:save("touched.jpg", { quality = 95 }))
local Formats = require("image.formats")
local Image = require("image.image")

---@class image
---@field Image image.Image # the class every decoded image is
---@field Animation image.Animation # what a multi frame file decodes into
local module = {}

module.Image = Image
module.Animation = Image.Animation

--- Reads a file and decodes its first frame.
---@type fun(path: string, options: image.DecodeOptions?): image.Image?, string?
module.load = Image.load

--- Decodes the first frame of an image, from the bytes of one.
---@type fun(data: string, options: image.DecodeOptions?): image.Image?, string?
module.decode = Image.decode

--- Reads a file and decodes every frame of it.
---@type fun(path: string, options: image.DecodeOptions?): image.Animation?, string?
module.loadFrames = Image.loadFrames

--- Decodes every frame of the bytes of an animation, and the one frame of anything
--- else, as an image.Animation.
---@type fun(data: string, options: image.DecodeOptions?): image.Animation?, string?
module.decodeFrames = Image.decodeFrames

--- What an image states about itself, without decoding its pixels.
---@type fun(data: string): image.Info?, string?
module.probe = Image.probe

--- Whether some bytes look like an image this package can decode.
---@type fun(data: string): boolean
module.isValid = Image.isValid

--- The name of the format these bytes are, by their signature alone.
---@type fun(data: string): string?
module.format = Image.format

--- An empty image of a given shape, or one wrapped around pixels the caller owns.
---@type fun(width: number, height: number, channels: number?, pixels: ffi.cdata*?): image.Image
module.new = Image.new

--- The names arisu-image went by, for a caller moving over from it.
---@type fun(path: string, options: image.DecodeOptions?): image.Image?, string?
module.fromPath = Image.load
---@type fun(data: string, options: image.DecodeOptions?): image.Image?, string?
module.fromData = Image.decode

--- Every format this package knows, by name, and whether it can be written as well
--- as read.
---@return table<string, boolean> # format name, then whether a save can produce it
function module.formats()
	local list = {}

	for _, format in ipairs(Formats.list) do
		list[format.name] = format.write ~= nil
	end

	return list
end

return module
