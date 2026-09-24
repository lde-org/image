-- The pattern the tests read, and a writer for each format a test can build by
-- hand.
--
-- The readers are checked against writers that share none of their code: the
-- builders below lay out the bytes of each format from its specification, and the
-- three files kept as fixtures are there because this package writes neither JPEG
-- nor GIF, so a reader test needs bytes from an encoder that is not the code under
-- test.
local bit = require("bit")

local images = {}

images.width = 4
images.height = 4

--- The pattern, row by row, as r, g, b, a: the primaries and white, then greys and
--- a half transparent black, then a diagonal of darker colours.
---@type number[][]
local PATTERN = {
	{ 255, 0, 0, 255 },
	{ 0, 255, 0, 255 },
	{ 0, 0, 255, 255 },
	{ 255, 255, 255, 255 },
	{ 0, 0, 0, 255 },
	{ 128, 128, 128, 255 },
	{ 0, 0, 0, 128 },
	{ 255, 255, 0, 255 },
	{ 255, 128, 0, 255 },
	{ 128, 0, 255, 255 },
	{ 0, 128, 128, 255 },
	{ 64, 64, 64, 255 },
	{ 255, 255, 255, 0 },
	{ 10, 20, 30, 255 },
	{ 200, 100, 50, 255 },
	{ 17, 34, 51, 255 },
}

--- The pattern's pixel at zero based coordinates.
---@param x number
---@param y number
---@return number r
---@return number g
---@return number b
---@return number a
function images.pattern(x, y)
	local pixel = PATTERN[y * images.width + x + 1]

	return pixel[1], pixel[2], pixel[3], pixel[4]
end

--- A grey pixel function, where all three colours are the same value, so a builder
--- never has to decide what grey a colour amounts to.
---@param value number
---@return fun(x: number, y: number): number, number, number, number
function images.grey(value)
	return function()
		return value, value, value, 255
	end
end

---@param value number
---@return string
local function le16(value)
	return string.char(value % 256, bit.band(bit.rshift(value, 8), 0xFF))
end

---@param value number
---@return string
local function le32(value)
	return string.char(value % 256, bit.band(bit.rshift(value, 8), 0xFF),
		bit.band(bit.rshift(value, 16), 0xFF), bit.band(bit.rshift(value, 24), 0xFF))
end

--- A big endian number, which is how PNG and QOI write theirs.
---@param value number
---@return string
function images.be32(value)
	return string.char(bit.band(bit.rshift(value, 24), 0xFF), bit.band(bit.rshift(value, 16), 0xFF),
		bit.band(bit.rshift(value, 8), 0xFF), value % 256)
end

local be32 = images.be32

--- Two bytes of a number, most significant first, which is how a netpbm sample
--- wider than one byte is stored.
---@param value number
---@return string
local function be16(value)
	return string.char(bit.band(bit.rshift(value, 8), 0xFF), value % 256)
end

--- The table the PNG chunk CRC is built from, made once.
---@type table<number, number>?
local CRC_TABLE = nil

--- The CRC a PNG chunk is checked with.
---@param data string
---@return number
local function crc32(data)
	if CRC_TABLE == nil then
		CRC_TABLE = {}

		for index = 0, 255 do
			local value = index

			for _ = 1, 8 do
				if bit.band(value, 1) == 1 then
					value = bit.bxor(bit.rshift(value, 1), 0xEDB88320)
				else
					value = bit.rshift(value, 1)
				end
			end

			CRC_TABLE[index] = value
		end
	end

	local table = CRC_TABLE
	local crc = -1

	for index = 1, #data do
		local slot = bit.band(bit.bxor(crc, string.byte(data, index)), 0xFF)
		crc = bit.bxor(bit.rshift(crc, 8), table[slot])
	end

	-- The bitwise library speaks signed 32 bit numbers, so the complement comes
	-- back negative and has to be put back into range.
	return bit.bnot(crc) % 0x100000000
end

--- The checksum a zlib stream ends with.
---@param data string
---@return number
local function adler32(data)
	local a, b = 1, 0

	for index = 1, #data do
		a = (a + string.byte(data, index)) % 65521
		b = (b + a) % 65521
	end

	return b * 65536 + a
end

--- A zlib stream of stored blocks: the one kind of deflate that needs no
--- compressor, which is why a test can write it out by hand.
---@param data string
---@return string
local function stored(data)
	local parts = { "\120\1" }
	local position = 1
	local last = false

	while not last do
		local block = string.sub(data, position, position + 65534)
		local length = #block

		-- An empty image still needs one block, which the last one of these is.
		last = position + length > #data

		parts[#parts + 1] = string.char(last and 1 or 0)
		parts[#parts + 1] = le16(length)
		parts[#parts + 1] = le16(bit.band(bit.bnot(length), 0xFFFF))
		parts[#parts + 1] = block

		position = position + length
	end

	parts[#parts + 1] = be32(adler32(data))

	return table.concat(parts)
end

---@param kind string
---@param data string
---@return string
local function chunk(kind, data)
	return be32(#data) .. kind .. data .. be32(crc32(kind .. data))
end

--- The bytes of a PNG, with its pixel data zlib stored rather than compressed.
---@param width number
---@param height number
---@param channels number # 1 grey, 2 grey and alpha, 3 colour, 4 colour and alpha
---@param pixel fun(x: number, y: number): number, number, number, number
---@return string
function images.png(width, height, channels, pixel)
	-- A pixel is stored in red, green, blue, alpha order whatever the colour type
	-- calls it, so grey takes the red channel and grey with alpha takes the alpha.
	local colourType = ({ 0, 4, 2, 6 })[channels]
	local rows = {}

	for y = 0, height - 1 do
		local row = { "\0" } -- the "none" row filter

		for x = 0, width - 1 do
			local r, g, b, a = pixel(x, y)

			if channels == 1 then
				row[#row + 1] = string.char(r)
			elseif channels == 2 then
				row[#row + 1] = string.char(r, a)
			elseif channels == 3 then
				row[#row + 1] = string.char(r, g, b)
			else
				row[#row + 1] = string.char(r, g, b, a)
			end
		end

		rows[#rows + 1] = table.concat(row)
	end

	local header = be32(width) .. be32(height) .. string.char(8, colourType, 0, 0, 0)

	return "\137PNG\r\n\26\n"
		.. chunk("IHDR", header)
		.. chunk("IDAT", stored(table.concat(rows)))
		.. chunk("IEND", "")
end

--- The bytes of a 24 bit Windows bitmap, which stores its rows bottom row first.
---@param width number
---@param height number
---@param pixel fun(x: number, y: number): number, number, number, number
---@return string
function images.bmp(width, height, pixel)
	local stride = math.floor((width * 3 + 3) / 4) * 4
	local rows = {}

	for y = height - 1, 0, -1 do
		local row = {}

		for x = 0, width - 1 do
			local r, g, b = pixel(x, y)
			-- A bitmap holds its colours blue first.
			row[#row + 1] = string.char(b, g, r)
		end

		rows[#rows + 1] = table.concat(row) .. string.rep("\0", stride - width * 3)
	end

	local raster = table.concat(rows)
	local header = "BM" .. le32(54 + #raster) .. le16(0) .. le16(0) .. le32(54)
	local info = le32(40) .. le32(width) .. le32(height) .. le16(1) .. le16(24)
		.. le32(0) .. le32(#raster) .. le32(2835) .. le32(2835) .. le32(0) .. le32(0)

	return header .. info .. raster
end

--- The bytes of an uncompressed Targa image, top row first.
---@param width number
---@param height number
---@param channels number # 1 grey, 2 grey and alpha, 3 colour, 4 colour and alpha
---@param pixel fun(x: number, y: number): number, number, number, number
---@return string
function images.tga(width, height, channels, pixel)
	local colour = channels >= 3
	local alpha = channels == 2 or channels == 4
	local depth = channels * 8

	-- Three is a grey image and two is a colour one, the size is little endian,
	-- and the top bit of the descriptor says the rows start at the top.
	local header = string.char(0, 0, colour and 2 or 3, 0, 0, 0, 0, 0, 0, 0, 0, 0)
		.. le16(width) .. le16(height) .. string.char(depth, bit.bor(alpha and 8 or 0, 32))

	local rows = {}

	for y = 0, height - 1 do
		local row = {}

		for x = 0, width - 1 do
			local r, g, b, a = pixel(x, y)

			if colour then
				row[#row + 1] = alpha and string.char(b, g, r, a) or string.char(b, g, r)
			else
				row[#row + 1] = alpha and string.char(r, a) or string.char(r)
			end
		end

		rows[#rows + 1] = table.concat(row)
	end

	return header .. table.concat(rows)
end

---@class tests.PnmOptions
---@field maxval number? # the largest sample, 255 unless a test says otherwise
---@field comments boolean? # writes a comment into the header

--- The bytes of a netpbm image, given as raw samples so a test can write a maximum
--- value other than 255.
---
--- P1 and P4 are bilevel, P2 and P5 grey, P3 and P6 colour; the odd ones write
--- their samples as numbers and the even ones as bytes, as the family's numbering
--- says.
---@param magic string # "P1" to "P6"
---@param width number
---@param height number
---@param options tests.PnmOptions?
---@param sample fun(x: number, y: number, channel: number): number
---@return string
function images.pnm(magic, width, height, options, sample)
	options = options or {}

	local maxval = options.maxval or 255
	local channels = (magic == "P3" or magic == "P6") and 3 or 1
	local bilevel = magic == "P1" or magic == "P4"
	local text = magic == "P1" or magic == "P2" or magic == "P3"

	local header = { magic, "\n" }

	if options.comments then
		header[#header + 1] = "# a comment, which the header may hold anywhere\n"
	end

	header[#header + 1] = string.format("%d %d\n", width, height)

	if not bilevel then
		header[#header + 1] = string.format("%d\n", maxval)
	end

	local raster = {}

	if magic == "P4" then
		-- Rows of bits, most significant first, each padded to a whole byte.
		local stride = math.floor((width + 7) / 8)

		for y = 0, height - 1 do
			local row = {}

			for index = 0, stride - 1 do
				local byte = 0

				for bit_index = 0, 7 do
					local x = index * 8 + bit_index

					if x < width and sample(x, y, 1) ~= 0 then
						byte = bit.bor(byte, bit.rshift(0x80, bit_index))
					end
				end

				row[#row + 1] = string.char(byte)
			end

			raster[#raster + 1] = table.concat(row)
		end
	elseif text then
		for y = 0, height - 1 do
			for x = 0, width - 1 do
				for channel = 1, channels do
					raster[#raster + 1] = string.format("%d ", sample(x, y, channel))
				end
			end

			raster[#raster + 1] = "\n"
		end
	else
		local wide = maxval > 255

		for y = 0, height - 1 do
			for x = 0, width - 1 do
				for channel = 1, channels do
					local value = sample(x, y, channel)

					if wide then
						raster[#raster + 1] = be16(math.floor(value))
					else
						raster[#raster + 1] = string.char(value)
					end
				end
			end
		end
	end

	return table.concat(header) .. table.concat(raster)
end

--- The bytes of a QOI stream, one whole pixel per op: the slowest and simplest way
--- to write the format, which is all a reader test needs.
---@param width number
---@param height number
---@param channels number # 3 or 4
---@param pixel fun(x: number, y: number): number, number, number, number
---@return string
function images.qoi(width, height, channels, pixel)
	local parts = {
		"qoif",
		be32(width),
		be32(height),
		string.char(channels, 0), -- sRGB
	}

	for y = 0, height - 1 do
		for x = 0, width - 1 do
			local r, g, b, a = pixel(x, y)

			if channels == 4 then
				parts[#parts + 1] = string.char(0xFF, r, g, b, a)
			else
				parts[#parts + 1] = string.char(0xFE, r, g, b)
			end
		end
	end

	parts[#parts + 1] = "\0\0\0\0\0\0\0\1"

	return table.concat(parts)
end

---@param name string
---@return string path
function images.path(name)
	return "tests/fixtures/" .. name
end

--- Reads a file, wherever it is.
---@param path string
---@return string
function images.read(path)
	local file = assert(io.open(path, "rb"), "the " .. path .. " fixture is missing")
	local data = file:read("*a")
	file:close()

	return data
end

--- Reads one of the fixtures kept as a file, by its name.
---@param name string
---@return string
function images.fixture(name)
	return images.read(images.path(name))
end

--- A path in the system temporary directory, for a test that writes a file.
---@param name string
---@return string
function images.temp(name)
	return os.tmpname() .. "-" .. name
end

--- Writes bytes to a path, for a test that needs a file to read back.
---@param path string
---@param data string
function images.write(path, data)
	local file = assert(io.open(path, "wb"))
	file:write(data)
	file:close()
end

return images
