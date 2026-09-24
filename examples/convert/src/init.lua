-- Converts an image from one format to another, the output format being the
-- extension of the file it is going to.
--
--	ldx convert --git https://github.com/bycruz/image -- photo.png photo.qoi
local image = require("image")

local input, output = arg and arg[1], arg and arg[2]

if input == nil or output == nil then
	print("usage: convert <input> <output>")
	print()
	print("The extension names the format to write: png, jpg, tga, bmp, qoi, ppm, pgm.")
	return
end

local file = io.open(input, "rb")

if file == nil then
	error("cannot open " .. input)
end

local bytes = file:read("*a")
file:close()

-- What the file says about itself, before any of its pixels are decoded.
local info = assert(image.probe(bytes), "not an image this can read")

print(string.format("%s: %s, %dx%d, %d channels", input, info.format.name, info.width, info.height,
	info.channels))

local img = assert(image.decode(bytes))

-- The format comes from the extension, from either side of the call, so saving is
-- the whole of the conversion. Quality is the one thing worth naming, and only a
-- jpeg has it.
local format = assert(string.match(output, "%.([%w]+)$"), "the output needs an extension")
local options = (format == "jpg" or format == "jpeg") and { quality = 95 } or nil

local encoded = assert(img:encode(format, options))
local written, err = img:save(output, options)

if written == nil then
	error(err)
end

print(string.format("%s: %d bytes, written as %s", output, #encoded, format))
