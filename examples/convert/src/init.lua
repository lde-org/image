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

---@param path string
---@return string bytes
local function read(path)
	local file = io.open(path, "rb")

	if file == nil then
		error("cannot open " .. path)
	end

	local bytes = file:read("*a")
	file:close()

	return bytes
end

local bytes = read(input)

-- What the file says about itself, before any of its pixels are decoded. The path
-- is passed along so that a format with no signature can be named by its file.
local info = assert(image.probe(bytes, input), "not an image this can read")
local name = info.format ~= nil and info.format.name or "an image with no signature"

print(string.format("%s: %s, %dx%d, %d channels", input, name, info.width, info.height, info.channels))

-- The format comes from the extension of the file the image is going to, so saving
-- is the whole of the conversion. Quality is the one thing worth naming, and only a
-- jpeg has it.
local written, err = assert(image.decode(bytes)):save(output, { quality = 95 })

if written == nil then
	error(err)
end

-- Reading it back is what says what was written, and how large it came out.
local produced = read(output)
local saved = assert(image.probe(produced, output))

print(string.format("%s: %s, %d bytes", output, saved.format.name, #produced))
