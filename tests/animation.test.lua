-- Animations: a GIF is the one format here that carries more than one frame, and
-- the frames of one live in a single buffer that its animation owns.
local test = require("lde-test")
local image = require("image")
local fixtures = require("tests.fixtures.images")

---@param img image.Image
---@param x number
---@param y number
---@return string
local function pixel(img, x, y)
	local r, g, b, a = img:getPixel(x, y)

	return string.format("%d,%d,%d,%d", r, g, b, a)
end

test.it("decodes every frame of a gif, with the time each one is shown for", function()
	local animation = assert(image.loadFrames(fixtures.path("animation.gif")))

	test.equal(animation.format.name, "GIF")
	test.equal(animation.width, 4)
	test.equal(animation.height, 4)
	test.equal(#animation.frames, 3, "three frames")

	test.equal(pixel(animation.frames[1], 2, 2), "255,0,0,255", "the first frame is red")
	test.equal(pixel(animation.frames[2], 2, 2), "0,255,0,255", "the second is green")
	test.equal(pixel(animation.frames[3], 2, 2), "0,0,255,255", "the third is blue")

	test.equal(animation.frames[1].delay, 100)
	test.equal(animation.frames[2].delay, 100)
	test.equal(animation.frames[3].delay, 200)

	test.equal(animation:duration(), 400, "a tenth of a second, then two more")
end)

test.it("decodes the one frame of a still as an animation of one", function()
	local animation = assert(image.loadFrames(fixtures.path("still.gif")))

	test.equal(#animation.frames, 1)
	test.equal(pixel(animation.frames[1], 2, 2), "255,128,0,255")
	test.equal(animation.frames[1].delay, nil, "a still says nothing about time")
	test.equal(animation:duration(), 0)

	local png = assert(image.decodeFrames(fixtures.png(2, 2, 4, fixtures.pattern)))

	test.equal(#png.frames, 1, "so does a format that never had more than one")
	test.equal(png.format.name, "PNG")
	test.equal(pixel(png.frames[1], 0, 0), "255,0,0,255")

	local qoi = assert(image.decodeFrames(fixtures.qoi(2, 2, 4, fixtures.pattern)))
	test.equal(#qoi.frames, 1, "a codec in Lua answers this too")
	test.equal(qoi.format.name, "QOI")
end)

test.it("decodes the first frame only, when that is all that was asked for", function()
	local first = assert(image.load(fixtures.path("animation.gif")))

	test.equal(pixel(first, 2, 2), "255,0,0,255")
	test.equal(first.delay, nil, "a whole animation is not one frame's delay")
	test.equal(first.format.name, "GIF")
end)

test.it("hands out frames that are images like any other", function()
	local animation = assert(image.loadFrames(fixtures.path("animation.gif")))
	local second = animation.frames[2]

	test.equal(second.width, 4)
	test.equal(second.height, 4)
	test.equal(second.channels, 4)
	test.equal(second.fileChannels, 4)

	-- The frames of one animation are offsets into the buffer stb filled, so each
	-- one has to answer for itself.
	local encoded = assert(second:encode("png"))
	local back = assert(image.decode(encoded))

	test.equal(pixel(back, 0, 0), "0,255,0,255", "the second frame is green all over")
	test.equal(pixel(back, 3, 3), "0,255,0,255")
end)

test.it("releases the buffer of an animation and leaves its frames empty", function()
	local animation = assert(image.loadFrames(fixtures.path("animation.gif")))

	animation:close()

	test.equal(animation.handle, nil)
	for _, frame in ipairs(animation.frames) do
		test.equal(frame.pixels, nil, "a frame cannot outlive the animation it was cut from")
	end
end)

test.it("keeps the buffer alive while a frame still points into it", function()
	local animation = assert(image.loadFrames(fixtures.path("animation.gif")))
	local frame = animation.frames[1]

	-- Dropping the animation is not closing it: the collector waits for the last
	-- reference, which this frame is.
	animation = nil
	collectgarbage()
	collectgarbage()

	test.equal(pixel(frame, 1, 1), "255,0,0,255")
end)
