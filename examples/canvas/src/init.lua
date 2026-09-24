-- Builds an image out of nothing but pixels, then writes it out in three
-- formats.
--
--	ldx canvas --git https://github.com/bycruz/image
--
-- A canvas is an ffi buffer and nothing else, so drawing on it is a loop of
-- setPixel calls: slower than a shader, but it needs no device and no window.
local image = require("image")

local WIDTH, HEIGHT = 256, 256

local canvas = image.new(WIDTH, HEIGHT, 4)

-- A gradient from dusk to dawn, a row at a time.
for y = 0, HEIGHT - 1 do
	local amount = y / (HEIGHT - 1)

	for x = 0, WIDTH - 1 do
		canvas:setPixel(x, y, 20 + amount * 235, 30 + amount * 90, 90 - amount * 40, 255)
	end
end

-- A checkerboard in the middle, blended over what is already there, which is what
-- reading a pixel back is for.
local SIZE = 8
local LEFT, TOP, SIDE = 64, 64, 128

for y = TOP, TOP + SIDE - 1 do
	for x = LEFT, LEFT + SIDE - 1 do
		local square = math.floor((x - LEFT) / SIZE) + math.floor((y - TOP) / SIZE)

		if square % 2 == 0 then
			local r, g, b = canvas:getPixel(x, y)
			canvas:setPixel(x, y, r * 0.7 + 76, g * 0.7 + 76, b * 0.7 + 76, 255)
		end
	end
end

-- A white frame around it, two pixels wide.
for y = TOP - 4, TOP + SIDE + 3 do
	for x = LEFT - 4, LEFT + SIDE + 3 do
		if x < LEFT or x > LEFT + SIDE - 1 or y < TOP or y > TOP + SIDE - 1 then
			canvas:setPixel(x, y, 255, 255, 255, 255)
		end
	end
end

--- Encodes an image and writes it out, reporting how large the file came out.
--- encode hands back the bytes, and save is that plus the file.
---@param target image.Image
---@param format string
---@param path string
---@param options image.EncodeOptions?
local function write(target, format, path, options)
	local encoded = assert(target:encode(format, options))
	assert(target:save(path, options))

	print(string.format("%-12s %7d bytes", path, #encoded))
end

write(canvas, "png", "canvas.png")
write(canvas, "qoi", "canvas.qoi")

-- JPEG is lossy and holds no alpha, so the file is smaller for the same picture.
write(canvas, "jpg", "canvas.jpg", { quality = 92 })

-- Reading one back is the same call, whatever the format was.
local reloaded = assert(image.load("canvas.png"))

print(string.format("canvas.png is %dx%d, %d channels", reloaded.width, reloaded.height, reloaded.channels))
print(string.format("its corner is %d,%d,%d", reloaded:getPixel(0, 0)))
