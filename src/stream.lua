-- A file read a frame at a time.
--
--   local stream = assert(image.stream("dance.gif"))
--
--   while true do
--     local frame = stream:next()
--     if frame == nil then break end
--     print(frame.delay, frame:getPixel(0, 0))
--   end
--
-- `loadFrames` is the whole animation at once: it costs the file's frames in time and in memory
-- before the first of them can be drawn, which for a gif of eighty frames of a photograph is a
-- fifth of a second and a hundred megabytes. A stream is the same animation a frame at a time --
-- stb walks the blocks of a GIF anyway, and this keeps that walk between calls -- so a caller
-- draws the first frame as soon as it has been read, and only ever holds the frames it keeps.
--
-- What it hands back is a picture of its own each time, copied out of the decoder's canvas, so a
-- frame outlives the call that made it. The two before it are kept by the stream itself, because
-- a GIF that disposes of a frame by restoring what was under it has to be shown what that was,
-- and those are let go of as it goes.
local ffi = require("ffi")
local Image = require("image.image")
local native = require("image.native")

---@class image.Stream
---@field path string
---@field width number # Of the frame read last, which is the size of all of them
---@field height number
---@field frame image.Image? # And the frame itself
local Stream = {}
Stream.__index = Stream

local function readFile(path)
	local file, err = io.open(path, "rb")

	if file == nil then
		return nil, "Failed to open " .. path .. ": " .. tostring(err)
	end

	local data = file:read("*a")
	file:close()

	if data == nil or data == "" then
		return nil, "Failed to read " .. path
	end

	return data
end

---@param path string
---@param data string
---@return image.Stream? stream
---@return string? err
function Stream.new(path, data)
	local handle, err = native.streamOpen(data)

	if handle == nil then
		return nil, err
	end

	return setmetatable({
		path = path,
		handle = handle,
		data = data,
		-- The frames the decoder has to be shown again: the one before the last, and the last.
		before = nil,
		last = nil,
		width = 0,
		height = 0,
		frame = nil,
	}, Stream)
end

--- Opens a file to be read a frame at a time.
---@param path string
---@return image.Stream? stream
---@return string? err
function Stream.open(path)
	local data, err = readFile(path)

	if data == nil then
		return nil, err
	end

	return Stream.new(path, data)
end

--- The frame after the last one read, or nothing when the file has no more of them. A file that
--- is not an animation is one frame, and nothing after it.
---
--- A read that fails rather than ending raises, because a file that stops in the middle of itself
--- is not a caller's to handle frame by frame.
---@return image.Image? frame
function Stream:next()
	if self.handle == nil then
		return nil
	end

	local twoBack = self.before and self.before.pixels or nil
	local pointer, width, height, delay, state = native.streamNext(self.handle, twoBack)

	if state == 0 then
		return nil
	end

	if state < 0 then
		error("Failed to read " .. self.path .. ": " .. tostring(native.reason()))
	end

	-- The decoder's canvas is reused by the next frame, so this one is copied out of it: a frame
	-- a caller keeps has to be its own.
	local pixels = ffi.new("uint8_t[?]", width * height * 4)

	ffi.copy(pixels, pointer, width * height * 4)

	local frame = Image.new(width, height, 4, pixels)

	frame.fileChannels = 4
	frame.delay = delay

	self.before, self.last = self.last, frame
	self.width, self.height, self.frame = width, height, frame

	return frame
end

--- Back to the first frame, which is what playing an animation again is. The two frames the
--- decoder is shown are let go of, since they belong to the run that just ended.
---@return image.Stream self
function Stream:rewind()
	if self.handle ~= nil then
		native.streamRewind(self.handle)
	end

	self.before, self.last, self.frame = nil, nil, nil

	return self
end

--- What the stream is holding: the two frames it keeps for the decoder, and nothing else. A
--- stream that is done with is closed rather than left to the collector, because the decoder's
--- canvas is a buffer of the size of one frame.
function Stream:close()
	if self.handle ~= nil then
		self.handle = nil
	end

	self.data, self.before, self.last, self.frame = nil, nil, nil, nil
end

---@return string
function Stream:__tostring()
	return string.format("<stream %s %dx%d>", self.path, self.width, self.height)
end

return Stream
