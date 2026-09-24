-- Reports what each image file holds: its format, its size, and how many frames
-- it carries.
--
--	ldx inspect --git https://github.com/bycruz/image -- photo.png animation.gif
local image = require("image")

local paths = arg or {}

if #paths == 0 then
	print("usage: inspect <image>...")
	print()
	print("Reads the header of each file for its shape, and decodes it when there is more")
	print("than one frame to report.")
	return
end

for _, path in ipairs(paths) do
	local file = io.open(path, "rb")

	if file == nil then
		print(string.format("%s: cannot be opened", path))
	else
		local bytes = file:read("*a")
		file:close()

		-- The header alone is enough for the shape, which is what a caller wants
		-- before it decides whether to decode a great many pixels. The path comes
		-- along because a format with no signature — TGA — can only be named by
		-- the file it came from.
		local info, err = image.probe(bytes, path)

		if info == nil then
			print(string.format("%s: %s", path, err))
		else
			print(string.format("%s: %s, %dx%d, %d channel%s, %d bit samples", path,
				info.format ~= nil and info.format.name or "an image with no signature",
				info.width, info.height, info.channels, info.channels == 1 and "" or "s", info.bits))

			-- A GIF can hold a whole sequence, and the frames carry the time each
			-- one is shown for.
			local animation = assert(image.decodeFrames(bytes))

			if #animation.frames > 1 then
				local delays = {}

				for _, frame in ipairs(animation.frames) do
					delays[#delays + 1] = tostring(frame.delay or 0)
				end

				print(string.format("\t%d frames, %s ms each, %d ms in all", #animation.frames,
					table.concat(delays, " and "), animation:duration()))
			end
		end
	end
end
