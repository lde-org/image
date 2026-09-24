local test = require("lde-test")
local image = require("image")
local fixtures = require("tests.fixtures.images")

local WIDTH = fixtures.width
local HEIGHT = fixtures.height

--- One pixel as a string, so a single assertion can compare all four channels.
---@param img image.Image
---@param x number
---@param y number
---@return string
local function pixel(img, x, y)
	local r, g, b, a = img:getPixel(x, y)

	return string.format("%d,%d,%d,%d", r, g, b, a)
end

--- Fails unless every pixel of an image is the pattern, as it reads through a
--- buffer of that many channels: a narrower buffer cannot say what alpha is, so a
--- grey image reads its one value in all three colours and a colour one reads as
--- opaque.
---@param img image.Image
---@param channels number
local function checkPattern(img, channels)
	test.equal(img.width, WIDTH, "width")
	test.equal(img.height, HEIGHT, "height")
	test.equal(img.channels, channels, "channels")

	for y = 0, HEIGHT - 1 do
		for x = 0, WIDTH - 1 do
			local r, g, b, a = fixtures.pattern(x, y)
			local expected

			if channels == 1 then
				expected = string.format("%d,%d,%d,255", r, r, r)
			elseif channels == 2 then
				expected = string.format("%d,%d,%d,%d", r, r, r, a)
			elseif channels == 3 then
				expected = string.format("%d,%d,%d,255", r, g, b)
			else
				expected = string.format("%d,%d,%d,%d", r, g, b, a)
			end

			test.equal(pixel(img, x, y), expected, string.format("the pixel at %d,%d", x, y))
		end
	end
end

---@param a number
---@param b number
---@param tolerance number?
---@return boolean
local function near(a, b, tolerance)
	return math.abs(a - b) <= (tolerance or 4)
end

test.it("decodes a png of every colour type it can hold", function()
	checkPattern(assert(image.decode(fixtures.png(WIDTH, HEIGHT, 4, fixtures.pattern))), 4)
	checkPattern(assert(image.decode(fixtures.png(WIDTH, HEIGHT, 3, fixtures.pattern))), 3)
	checkPattern(assert(image.decode(fixtures.png(WIDTH, HEIGHT, 2, fixtures.pattern))), 2)
	checkPattern(assert(image.decode(fixtures.png(WIDTH, HEIGHT, 1, fixtures.pattern))), 1)
end)

test.it("decodes a grey png, whichever value it holds", function()
	for _, value in ipairs({ 0, 76, 128, 255 }) do
		local img = assert(image.decode(fixtures.png(2, 2, 1, fixtures.grey(value))))

		test.equal(img.channels, 1, "grey holds one channel")
		test.equal(pixel(img, 1, 1), string.format("%d,%d,%d,255", value, value, value))
	end
end)

test.it("decodes a bitmap, a targa and a netpbm image", function()
	checkPattern(assert(image.decode(fixtures.bmp(WIDTH, HEIGHT, fixtures.pattern))), 3)
	checkPattern(assert(image.decode(fixtures.tga(WIDTH, HEIGHT, 4, fixtures.pattern))), 4)

	-- A grey targa, with a value for every pixel, which is what says whether the
	-- rows came out the way they went in.
	local grey = assert(image.decode(fixtures.tga(WIDTH, HEIGHT, 1, function(x, y)
		local value = y * 64 + x * 16

		return value, value, value, 255
	end)))

	test.equal(grey.channels, 1)
	test.equal(pixel(grey, 0, 0), "0,0,0,255")
	test.equal(pixel(grey, 1, 0), "16,16,16,255", "across the row")
	test.equal(pixel(grey, 0, 1), "64,64,64,255", "down the rows, top first")
	test.equal(pixel(grey, WIDTH - 1, HEIGHT - 1), "240,240,240,255", "and the last of them")

	local ppm = fixtures.pnm("P6", WIDTH, HEIGHT, nil, function(x, y, channel)
		local r, g, b = fixtures.pattern(x, y)

		return ({ r, g, b })[channel]
	end)

	checkPattern(assert(image.decode(ppm)), 3)
end)

test.it("decodes a qoi stream", function()
	checkPattern(assert(image.decode(fixtures.qoi(WIDTH, HEIGHT, 4, fixtures.pattern))), 4)
	checkPattern(assert(image.decode(fixtures.qoi(WIDTH, HEIGHT, 3, fixtures.pattern))), 3)
end)

test.it("decodes a jpeg, near enough for a lossy one", function()
	local photo = assert(image.decode(fixtures.fixture("photo.jpg")))

	test.equal(photo.format.name, "JPEG")
	test.equal(photo.width, 64)
	test.equal(photo.height, 64)
	test.equal(photo.channels, 3)

	local r, g, b = photo:getPixel(0, 0)
	test.truthy(near(r, 255) and near(g, 0) and near(b, 0), "the left half is red")

	r, g, b = photo:getPixel(63, 63)
	test.truthy(near(r, 0) and near(g, 0) and near(b, 255), "the right half is blue")
end)

test.it("reads and writes a pixel at a time", function()
	local img = image.new(3, 2, 4)

	test.equal(img:getPixel(2, 1), 0, "a new image is transparent black")
	test.equal(select(4, img:getPixel(2, 1)), 0)

	img:setPixel(2, 1, 10, 20, 30, 40)
	test.equal(pixel(img, 2, 1), "10,20,30,40")
	test.equal(pixel(img, 0, 0), "0,0,0,0", "the other pixels did not move")

	img:fill(1, 2, 3, 4)
	test.equal(pixel(img, 0, 0), "1,2,3,4")

	test.errors(function()
		img:getPixel(3, 0)
	end, nil, "reading outside the image is an error")

	test.errors(function()
		img:setPixel(0, 2, 0, 0, 0, 0)
	end, nil, "writing outside the image is an error")
end)

test.it("reads and writes a grey image as grey", function()
	local img = image.new(1, 1, 1)
	img:setPixel(0, 0, 255, 0, 0)

	-- A colour becomes the grey it amounts to, by the weighting the codecs use.
	test.equal(pixel(img, 0, 0), "76,76,76,255")

	local grey = image.new(1, 1, 2)
	grey:setPixel(0, 0, 10, 20, 30, 40)
	test.equal(pixel(grey, 0, 0), "18,18,18,40", "grey with alpha keeps the alpha")
end)

test.it("converts between channel counts", function()
	local img = assert(image.decode(fixtures.png(WIDTH, HEIGHT, 4, fixtures.pattern)))

	local opaque = img:convert(3)
	test.equal(opaque.channels, 3, "colour without alpha")
	test.equal(pixel(opaque, 2, 1), "0,0,0,255", "the half transparent pixel reads as opaque")

	local grey = opaque:convert(1)
	test.equal(grey.channels, 1, "one channel")
	test.equal(pixel(grey, 0, 0), "76,76,76,255", "red, by weight")
	test.equal(pixel(grey, 1, 1), "128,128,128,255", "a grey stays put")

	local widened = grey:convert(4)
	test.equal(pixel(widened, 0, 0), "76,76,76,255", "a grey widens to an opaque colour")
end)

test.it("copies an image without sharing its pixels", function()
	local img = assert(image.decode(fixtures.png(WIDTH, HEIGHT, 4, fixtures.pattern)))
	local copy = img:copy()

	copy:setPixel(0, 0, 1, 2, 3, 4)

	test.equal(pixel(copy, 0, 0), "1,2,3,4")
	test.equal(pixel(img, 0, 0), "255,0,0,255", "the original did not move")
end)

test.it("turns an image upside down", function()
	local img = assert(image.decode(fixtures.png(WIDTH, HEIGHT, 4, fixtures.pattern)))
	img:flip()

	test.equal(pixel(img, 0, 0), "255,255,255,0", "the last row is the first one now")
	test.equal(pixel(img, 0, HEIGHT - 1), "255,0,0,255")

	img:flip()
	test.equal(pixel(img, 0, 0), "255,0,0,255", "flipping twice is where it started")
end)

test.it("turns an image upside down while decoding it", function()
	local img = assert(image.decode(fixtures.png(WIDTH, HEIGHT, 4, fixtures.pattern), { flip = true }))

	test.equal(pixel(img, 0, 0), "255,255,255,0")
end)

test.it("probes a file without decoding its pixels", function()
	local info = assert(image.probe(fixtures.png(WIDTH, HEIGHT, 4, fixtures.pattern)))

	test.equal(info.format.name, "PNG")
	test.equal(info.width, WIDTH)
	test.equal(info.height, HEIGHT)
	test.equal(info.channels, 4)
	test.equal(info.bits, 8)

	local qoi = assert(image.probe(fixtures.qoi(WIDTH, HEIGHT, 3, fixtures.pattern)))
	test.equal(qoi.format.name, "QOI")
	test.equal(qoi.channels, 3)

	local ppm = assert(image.probe(fixtures.pnm("P6", WIDTH, HEIGHT, nil, function()
		return 0
	end)))
	test.equal(ppm.format.name, "PPM")

	local photo = assert(image.probe(fixtures.fixture("photo.jpg")))
	test.equal(photo.format.name, "JPEG")
	test.equal(photo.width, 64)
	test.equal(photo.channels, 3)

	local info2, err = image.probe("this is not an image")
	test.falsy(info2)
	test.truthy(err)
end)

test.it("probes a format that has no signature, when the path says which it is", function()
	local tga = fixtures.tga(WIDTH, HEIGHT, 4, fixtures.pattern)

	local unnamed = assert(image.probe(tga))
	test.equal(unnamed.format, nil, "the bytes alone cannot say which format this is")

	local info = assert(image.probe(tga, "picture.tga"))
	test.equal(info.format.name, "TGA")
	test.equal(info.width, WIDTH)
	test.equal(info.channels, 4)
end)

test.it("identifies the format from the signature alone", function()
	test.equal(image.identify(fixtures.png(WIDTH, HEIGHT, 4, fixtures.pattern)), "PNG")
	test.equal(image.identify(fixtures.fixture("photo.jpg")), "JPEG")
	test.equal(image.identify(fixtures.fixture("animation.gif")), "GIF")
	test.equal(image.identify(fixtures.qoi(WIDTH, HEIGHT, 4, fixtures.pattern)), "QOI")
	test.equal(image.identify(fixtures.bmp(WIDTH, HEIGHT, fixtures.pattern)), "BMP")
	test.equal(image.identify("this is not an image"), nil, "text has no signature")
end)

test.it("knows what it can decode, even without a signature", function()
	local tga = fixtures.tga(WIDTH, HEIGHT, 4, fixtures.pattern)

	test.equal(image.identify(tga), nil, "a targa has nothing to go by")
	test.truthy(image.isValid(tga), "and is still decodable")
	test.truthy(image.isValid(fixtures.qoi(WIDTH, HEIGHT, 4, fixtures.pattern)))
	test.truthy(image.isValid(fixtures.fixture("photo.jpg")))
	test.falsy(image.isValid("this is not an image"))
end)

test.it("names the format of a file it read, even without a signature", function()
	local path = fixtures.temp("hinted.tga")
	fixtures.write(path, fixtures.tga(WIDTH, HEIGHT, 4, fixtures.pattern))

	local loaded = assert(image.load(path))
	test.equal(loaded.format.name, "TGA")

	local animation = assert(image.loadFrames(path))
	test.equal(#animation.frames, 1)
	test.equal(animation.format.name, "TGA", "the frames are of the file's format too")
	test.equal(pixel(animation.frames[1], 0, 0), "255,0,0,255")

	os.remove(path)
end)

test.it("saves and loads a file, in the format its extension names", function()
	local source = assert(image.decode(fixtures.png(WIDTH, HEIGHT, 4, fixtures.pattern)))
	local lossless = { "png", "tga", "qoi", "ppm" }

	for _, extension in ipairs(lossless) do
		local path = fixtures.temp("saved." .. extension)

		test.truthy((source:save(path)), "saving as " .. extension)

		local reloaded = assert(image.load(path), "loading the " .. extension .. " back")
		test.equal(reloaded.width, WIDTH, extension .. " width")
		test.equal(reloaded.height, HEIGHT, extension .. " height")
		test.truthy(reloaded.format ~= nil, extension .. " was named")

		os.remove(path)
	end

	-- A bitmap holds colour without alpha, and a jpeg is lossy, so those two are
	-- checked for their shape and a colour rather than pixel for pixel.
	local opaque = source:convert(3)

	local bitmap = fixtures.temp("saved.bmp")
	assert(opaque:save(bitmap))

	local reloaded = assert(image.load(bitmap))
	test.equal(reloaded.width, WIDTH, "bitmap width")
	test.equal(reloaded.channels, 3, "bitmap channels")
	checkPattern(reloaded, 3)

	os.remove(bitmap)

	-- A bitmap of four channels is a different header from the 24 bit one, and the
	-- alpha in it has to survive.
	local alpha = fixtures.temp("saved-32bit.bmp")
	assert(source:save(alpha))

	local kept = assert(image.load(alpha))
	test.equal(kept.channels, 4, "a 32 bit bitmap keeps its alpha")
	test.equal(pixel(kept, 2, 1), "0,0,0,128", "the half transparent pixel is still half transparent")

	os.remove(alpha)

	-- Quality 95 leaves the chroma alone, so a four pixel image comes back close
	-- to where it started.
	local jpeg = fixtures.temp("saved.jpg")
	assert(opaque:save(jpeg, { quality = 95 }))

	local photo = assert(image.load(jpeg))
	test.equal(photo.width, WIDTH, "jpeg width")
	test.equal(photo.channels, 3, "jpeg channels")

	local r, g, b = photo:getPixel(0, 0)
	test.truthy(near(r, 255, 16) and near(g, 0, 16) and near(b, 0, 16), "a jpeg keeps the colours near enough")

	os.remove(jpeg)
end)

test.it("writes a png when nothing says otherwise", function()
	local img = assert(image.decode(fixtures.png(WIDTH, HEIGHT, 4, fixtures.pattern)))
	local path = fixtures.temp("untitled")
	assert(img:save(path))

	test.equal(image.identify(fixtures.read(path)), "PNG")

	os.remove(path)
end)

test.it("reports a file it cannot read", function()
	local path = fixtures.temp("not-an-image")
	fixtures.write(path, "this is not an image at all")

	local img, err = image.load(path)
	test.falsy(img)
	test.truthy(err)
	test.includes(err, "unknown image type", "the decoder says why")

	os.remove(path)

	local missing, missingErr = image.load("tests/fixtures/does-not-exist.png")
	test.falsy(missing)
	test.includes(missingErr, "Failed to open")

	local truncated, truncatedErr = image.decode(string.sub(fixtures.png(WIDTH, HEIGHT, 4, fixtures.pattern), 1, 40))
	test.falsy(truncated)
	test.truthy(truncatedErr)
end)

test.it("refuses what it cannot write", function()
	local img = assert(image.decode(fixtures.png(WIDTH, HEIGHT, 4, fixtures.pattern)))

	local encoded, err = img:encode("webp")
	test.falsy(encoded)
	test.includes(err, "Unknown image format")

	local path = fixtures.temp("thing.wibble")
	local saved, saveErr = img:save(path)
	test.falsy(saved)
	test.includes(saveErr, "Unknown image format")

	local gif, gifErr = img:encode("gif")
	test.falsy(gif)
	test.includes(gifErr, "cannot be written")

	local grey = image.new(WIDTH, HEIGHT, 1)
	local bmp, bmpErr = grey:encode("bmp")
	test.falsy(bmp)
	test.includes(bmpErr, "channel")
end)

test.it("releases the pixels of an image it decoded, and empties it", function()
	local decoded = assert(image.decode(fixtures.png(WIDTH, HEIGHT, 4, fixtures.pattern)))

	test.truthy(decoded.handle ~= nil, "a decoded image holds the handle its pixels live in")
	test.truthy(decoded.pixels ~= nil)

	decoded:close()

	test.equal(decoded.handle, nil, "the handle is what released them")
	test.equal(decoded.pixels, nil, "and a closed image has nothing to read")

	-- Closing twice must not free twice.
	decoded:close()
	test.equal(decoded.handle, nil)

	collectgarbage()
	collectgarbage()
end)

test.it("lets go of an image it owns without taking a shared buffer with it", function()
	local built = image.new(WIDTH, HEIGHT, 4)

	test.equal(built.handle, nil, "an image made here owns no native handle")

	built:close()
	test.equal(built.pixels, nil, "closing leaves it empty too")

	-- The frames of an animation share one buffer, and it is the animation that
	-- lets it go: closing one frame must leave the others readable.
	local animation = assert(image.decodeFrames(fixtures.fixture("animation.gif")))
	local frame = animation.frames[1]

	frame:close()

	test.equal(frame.pixels, nil, "the frame that was closed is empty")
	test.truthy(animation.frames[2].pixels ~= nil, "the frames that were not still have theirs")
	test.equal(pixel(animation.frames[2], 2, 2), "0,255,0,255", "and still read what they held")

	animation:close()

	for _, remaining in ipairs(animation.frames) do
		test.equal(remaining.pixels, nil, "closing the animation empties every frame")
	end
end)

test.it("lists the formats it knows, and which of them it can write", function()
	local formats = image.formats()

	test.equal(formats.PNG, true)
	test.equal(formats.JPEG, true)
	test.equal(formats.TGA, true)
	test.equal(formats.BMP, true)
	test.equal(formats.QOI, true)
	test.equal(formats.PPM, true)
	test.equal(formats.PGM, true)
	test.equal(formats.GIF, false, "a gif can be read but not written")
	test.equal(formats.PSD, false)
	test.equal(formats.PBM, false)
end)

test.it("refuses an image with no room in it", function()
	test.errors(function()
		image.new(0, 4)
	end)

	test.errors(function()
		image.new(4, 4, 5)
	end)
end)
