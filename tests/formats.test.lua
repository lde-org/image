-- The formats whose bytes a test can lay out by hand, and the ops a QOI stream is
-- made of. Both codecs read streams that are written here op by op, so what is
-- tested is the decoder against the specification rather than against itself.
local test = require("lde-test")
local image = require("image")
local fixtures = require("tests.fixtures.images")

local WIDTH = fixtures.width
local HEIGHT = fixtures.height

--- The colour of one pixel of the pattern, as a single string.
---@param img image.Image
---@param x number
---@param y number
---@return string
local function pixel(img, x, y)
	local r, g, b, a = img:getPixel(x, y)

	return string.format("%d,%d,%d,%d", r, g, b, a)
end

--- A complete QOI stream from the ops a test spells out.
---@param width number
---@param height number
---@param channels number
---@param ops string
---@return string
local function qoi(width, height, channels, ops)
	return "qoif" .. fixtures.be32(width) .. fixtures.be32(height) .. string.char(channels, 0)
		.. ops .. "\0\0\0\0\0\0\0\1"
end

--- The pattern's samples, one channel at a time, for a netpbm builder.
---@param x number
---@param y number
---@param channel number
---@return number
local function sample(x, y, channel)
	local r, g, b = fixtures.pattern(x, y)

	return ({ r, g, b })[channel]
end

test.it("reads a binary netpbm image", function()
	local ppm = assert(image.decode(fixtures.pnm("P6", WIDTH, HEIGHT, nil, sample)))
	test.equal(ppm.format.name, "PPM")
	test.equal(ppm.channels, 3)

	for y = 0, HEIGHT - 1 do
		for x = 0, WIDTH - 1 do
			local r, g, b = fixtures.pattern(x, y)
			test.equal(pixel(ppm, x, y), string.format("%d,%d,%d,255", r, g, b))
		end
	end
end)

test.it("reads a netpbm header with a comment in it", function()
	local ppm = fixtures.pnm("P6", 2, 1, { comments = true }, function(x, _, channel)
		return (x == 0 and channel == 1) and 255 or 0
	end)

	local img = assert(image.decode(ppm))
	test.equal(pixel(img, 0, 0), "255,0,0,255")
	test.equal(pixel(img, 1, 0), "0,0,0,255")
end)

test.it("reads a grey netpbm image, as numbers or as bytes", function()
	local binary = assert(image.decode(fixtures.pnm("P5", 2, 1, nil, function(x)
		return x == 0 and 0 or 255
	end)))

	test.equal(binary.channels, 1)
	test.equal(pixel(binary, 0, 0), "0,0,0,255")
	test.equal(pixel(binary, 1, 0), "255,255,255,255")

	local ascii = assert(image.decode(fixtures.pnm("P2", 3, 1, nil, function(x)
		return ({ 10, 128, 200 })[x + 1]
	end)))

	test.equal(ascii.channels, 1)
	test.equal(pixel(ascii, 0, 0), "10,10,10,255")
	test.equal(pixel(ascii, 1, 0), "128,128,128,255")
	test.equal(pixel(ascii, 2, 0), "200,200,200,255")
end)

test.it("scales a netpbm sample by the maximum the header states", function()
	-- Fifteen is the largest sample, so it stands for white.
	local small = assert(image.decode(
		fixtures.pnm("P2", 3, 1, { maxval = 15 }, function(x)
			return ({ 0, 7, 15 })[x + 1]
		end)))

	test.equal(pixel(small, 0, 0), "0,0,0,255")
	test.equal(pixel(small, 1, 0), "119,119,119,255")
	test.equal(pixel(small, 2, 0), "255,255,255,255")

	-- Two bytes a sample, narrowed to one: 257 is 65535 divided by 255 exactly.
	local wide = assert(image.decode(
		fixtures.pnm("P5", 2, 1, { maxval = 65535 }, function(x)
			return x == 0 and 257 or 65535
		end)))

	test.equal(pixel(wide, 0, 0), "1,1,1,255")
	test.equal(pixel(wide, 1, 0), "255,255,255,255")
end)

test.it("reads a sample that says more than the maximum allows", function()
	-- A file may spell out a number larger than its own maximum, which is the
	-- brightest value there is rather than one wrapped around.
	local beyond = assert(image.decode("P2\n2 1\n255\n300 128\n"))

	test.equal(pixel(beyond, 0, 0), "255,255,255,255", "a sample past the maximum is white")
	test.equal(pixel(beyond, 1, 0), "128,128,128,255")

	local scaled = assert(image.decode("P2\n2 1\n15\n99 0\n"))

	test.equal(pixel(scaled, 0, 0), "255,255,255,255")
	test.equal(pixel(scaled, 1, 0), "0,0,0,255")
end)

test.it("refuses a header that is not one of the six netpbm formats", function()
	for _, magic in ipairs({ "P0", "P7", "P9" }) do
		local img, err = image.decode(magic .. "\n2 1\n255\n\1\2\3\4\5\6")

		test.falsy(img, magic .. " is not a netpbm format")
		test.truthy(err)
	end

	-- A PAM file, which shares the P and the idea of one but not the header.
	local pam, pamErr = image.decode("P7\nWIDTH 2\nHEIGHT 1\nDEPTH 3\nMAXVAL 255\nENDHDR\n\1\2\3\4\5\6")
	test.falsy(pam)
	test.truthy(pamErr)
end)

test.it("reads a bilevel image whose rows do not fill a byte", function()
	local width, height = 5, 2

	local img = assert(image.decode(fixtures.pnm("P4", width, height, nil, function(x, y)
		return (x + y) % 2 == 0 and 1 or 0
	end)))

	for y = 0, height - 1 do
		for x = 0, width - 1 do
			-- Each row is padded out to a whole byte, which the padding must not
			-- turn into pixels.
			local expected = (x + y) % 2 == 0 and "0,0,0,255" or "255,255,255,255"

			test.equal(pixel(img, x, y), expected, string.format("the pixel at %d,%d", x, y))
		end
	end
end)

test.it("reads a bilevel netpbm image", function()
	-- Rows of bits, most significant first: 10101010 is black, white and so on.
	local binary = assert(image.decode(fixtures.pnm("P4", 8, 1, nil, function(x)
		return x % 2 == 0 and 1 or 0
	end)))

	test.equal(binary.channels, 1)
	test.equal(pixel(binary, 0, 0), "0,0,0,255", "a set bit is black")
	test.equal(pixel(binary, 1, 0), "255,255,255,255")

	local ascii = assert(image.decode(fixtures.pnm("P1", 2, 2, nil, function(x, y)
		return x == y and 1 or 0
	end)))

	test.equal(pixel(ascii, 0, 0), "0,0,0,255")
	test.equal(pixel(ascii, 1, 0), "255,255,255,255")
	test.equal(pixel(ascii, 0, 1), "255,255,255,255")
	test.equal(pixel(ascii, 1, 1), "0,0,0,255")
end)

test.it("reports a netpbm image that does not say enough", function()
	local short = string.sub(fixtures.pnm("P6", WIDTH, HEIGHT, nil, sample), 1, 20)
	local img, err = image.decode(short)

	test.falsy(img)
	test.truthy(err)

	local noMaximum, maximumErr = image.decode("P6\n2 2\n")
	test.falsy(noMaximum)
	test.truthy(maximumErr)

	local noSize, sizeErr = image.decode("P5\n")
	test.falsy(noSize)
	test.truthy(sizeErr)

	-- A header claiming sixteen million pixels that the raster cannot begin to
	-- hold is refused before anything is allocated for them.
	local huge, hugeErr = image.decode("P6\n4000 4000\n255\n\0\0\0")
	test.falsy(huge)
	test.includes(hugeErr, "shorter than the header claims")
end)

test.it("reads every op a qoi stream is made of", function()
	-- A whole pixel, then the same one out of the index it just went into.
	local index = assert(image.decode(qoi(2, 1, 4, string.char(0xFF, 10, 20, 30, 40, 12))))

	test.equal(pixel(index, 0, 0), "10,20,30,40")
	test.equal(pixel(index, 1, 0), "10,20,30,40", "the index gave back what it was given")

	-- A whole pixel, then one two bits a channel away from it.
	local diff = assert(image.decode(qoi(2, 1, 4, string.char(0xFF, 100, 100, 100, 255, 0x40 + (3 * 16) + (1 * 4) + 2))))

	test.equal(pixel(diff, 0, 0), "100,100,100,255")
	test.equal(pixel(diff, 1, 0), "101,99,100,255", "one up, one down")

	-- A whole pixel, then a difference carried as a green one and two against it.
	local luma = assert(image.decode(qoi(2, 1, 4, string.char(0xFF, 100, 100, 100, 255, 0x80 + 42, (10 * 16) + 5))))

	test.equal(pixel(luma, 0, 0), "100,100,100,255")
	test.equal(pixel(luma, 1, 0), "112,110,107,255")

	-- A whole pixel, and a run op repeating it twice more.
	local run = assert(image.decode(qoi(3, 1, 4, string.char(0xFF, 7, 8, 9, 10, 0xC2))))

	test.equal(pixel(run, 0, 0), "7,8,9,10")
	test.equal(pixel(run, 1, 0), "7,8,9,10")
	test.equal(pixel(run, 2, 0), "7,8,9,10")

	-- A three channel stream has no alpha to carry, so every pixel is opaque.
	local opaque = assert(image.decode(qoi(1, 1, 3, string.char(0xFE, 1, 2, 3))))

	test.equal(opaque.channels, 3)
	test.equal(pixel(opaque, 0, 0), "1,2,3,255")
end)

test.it("reads a qoi stream that closes without its end marker", function()
	-- The format asks for a marker, and a stream that stops after its last op is
	-- still readable: sixty-two pixels can come out of one byte of it.
	local stream = "qoif" .. fixtures.be32(100) .. fixtures.be32(1) .. "\4\0"
		.. string.char(0xFF, 7, 200, 9, 10) -- a whole pixel
		.. string.char(0xC0 + 61) -- sixty-two of it
		.. string.char(0xC0 + 36) -- and thirty-seven more

	local img = assert(image.decode(stream))

	test.equal(img.width, 100)
	test.equal(pixel(img, 0, 0), "7,200,9,10")
	test.equal(pixel(img, 99, 0), "7,200,9,10")
end)

test.it("reports a qoi stream that does not add up", function()
	local img, err = image.decode("qoif")
	test.falsy(img)
	test.includes(err, "too short")

	local wrongMagic, magicErr = image.decode(string.sub(qoi(1, 1, 4, string.char(0xFF, 1, 2, 3, 4)), 2))
	test.falsy(wrongMagic)
	test.truthy(magicErr)

	local empty, emptyErr = image.decode(qoi(0, 4, 4, ""))
	test.falsy(empty)
	test.includes(emptyErr, "empty")

	-- The header claims four pixels and the stream spells out one.
	local short, shortErr = image.decode(qoi(4, 1, 4, string.char(0xFF, 1, 2, 3, 4)))
	test.falsy(short)
	test.truthy(shortErr)

	local tooMany, manyErr = image.decode(qoi(64, 64, 4, string.char(0xC0)))
	test.falsy(tooMany)
	test.includes(manyErr, "more pixels")
end)

test.it("writes a qoi stream it can read back", function()
	local source = assert(image.decode(fixtures.png(WIDTH, HEIGHT, 4, fixtures.pattern)))
	local encoded = assert(source:encode("qoi"))

	test.equal(string.sub(encoded, 1, 4), "qoif")
	test.equal(string.sub(encoded, #encoded - 7), "\0\0\0\0\0\0\0\1", "the end marker closes it")

	local back = assert(image.decode(encoded))
	test.equal(back.channels, 4)

	for y = 0, HEIGHT - 1 do
		for x = 0, WIDTH - 1 do
			test.equal(pixel(back, x, y), pixel(source, x, y))
		end
	end
end)

test.it("writes a run op for every sixty-two pixels that repeat", function()
	-- The op stream is short enough to spell out: a whole pixel, then a run op per
	-- sixty-two repeats of it. A run op carries its length less one.
	local header = "qoif" .. fixtures.be32(0) .. fixtures.be32(0) .. "\4\0"

	---@param count number
	---@return string
	local function expected(count)
		local ops = string.char(0xFF, 7, 200, 9, 10)

		local repeats = count - 1
		while repeats > 0 do
			local run = math.min(repeats, 62)
			ops = ops .. string.char(0xC0 + run - 1)
			repeats = repeats - run
		end

		return string.sub(header, 1, 4)
			.. fixtures.be32(count) .. fixtures.be32(1)
			.. "\4\0" .. ops .. "\0\0\0\0\0\0\0\1"
	end

	for _, count in ipairs({ 1, 62, 63, 125 }) do
		local img = image.new(count, 1, 4)
		img:fill(7, 200, 9, 10)

		local encoded = assert(img:encode("qoi"))

		test.equal(encoded, expected(count), count .. " pixels of one colour")
		test.equal(pixel(assert(image.decode(encoded)), count - 1, 0), "7,200,9,10")
	end
end)

test.it("refuses to write the channel counts qoi cannot describe", function()
	local grey = image.new(2, 1, 1)
	grey:setPixel(0, 0, 90, 90, 90, 255)
	grey:setPixel(1, 0, 200, 200, 200, 255)

	local encoded, err = grey:encode("qoi")

	test.falsy(encoded)
	test.includes(err, "A QOI holds 3 or 4 channel pixels")

	-- Widened, it is a stream like any other.
	local widened = assert(grey:convert(3):encode("qoi"))
	local back = assert(image.decode(widened))

	test.equal(back.channels, 3)
	test.equal(pixel(back, 0, 0), "90,90,90,255")
	test.equal(pixel(back, 1, 0), "200,200,200,255", "the second pixel is not the first one's tail")
end)

test.it("compresses a qoi stream that repeats itself", function()
	local solid = image.new(64, 64, 4)
	solid:fill(7, 8, 9, 10)

	local encoded = assert(solid:encode("qoi"))

	-- A whole pixel per pixel would be five bytes each, and a run op carries
	-- sixty-two of them at once.
	test.less(#encoded, 64 * 64, "a run of one colour is not written out pixel by pixel")

	local back = assert(image.decode(encoded))
	test.equal(pixel(back, 63, 63), "7,8,9,10")
end)

test.it("writes a netpbm image it can read back", function()
	local source = assert(image.decode(fixtures.png(WIDTH, HEIGHT, 3, fixtures.pattern)))

	local ppm = assert(source:encode("ppm"))
	test.equal(string.sub(ppm, 1, 3), "P6\n")
	test.equal(string.sub(ppm, 4, 10), "4 4\n255")

	local back = assert(image.decode(ppm))
	test.equal(back.format.name, "PPM")

	for y = 0, HEIGHT - 1 do
		for x = 0, WIDTH - 1 do
			test.equal(pixel(back, x, y), pixel(source, x, y))
		end
	end

	-- A grey image, from the same colour one: the weighting turns each pixel into
	-- the one value the format holds.
	local pgm = assert(source:encode("pgm"))
	test.equal(string.sub(pgm, 1, 3), "P5\n")
	test.equal(#pgm, 11 + WIDTH * HEIGHT)

	local grey = assert(image.decode(pgm))
	test.equal(grey.channels, 1)
	test.equal(pixel(grey, 0, 0), "76,76,76,255", "red becomes the grey it amounts to")
end)

test.it("writes a netpbm file without the alpha it cannot hold", function()
	local source = assert(image.decode(fixtures.png(WIDTH, HEIGHT, 4, fixtures.pattern)))

	local ppm = assert(source:encode("ppm"))
	local back = assert(image.decode(ppm))

	test.equal(back.channels, 3, "the pixels were narrowed on the way out")
	test.equal(pixel(back, 2, 1), "0,0,0,255")
end)
