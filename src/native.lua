-- The stb_image bindings, over the shared library build.lua compiles.
--
-- This is the package's whole C surface. A decode hands back an opaque handle: the
-- pixels stb allocated live and die with it, so Lua holds the handle for as long as
-- it wants the pixels and nothing else. Every handle carries a finalizer, which is
-- what frees them when an image is dropped without being closed.
local ffi = require("ffi")

--- The directory a file was loaded from, from the name the runtime knows it by.
---@param source string
---@return string
local function directory(source)
	-- A source name is prefixed with "@" when it names a file on disk.
	local path = string.sub(source, 1, 1) == "@" and string.sub(source, 2) or source

	for index = #path, 1, -1 do
		local byte = string.byte(path, index)

		if byte == 0x2F or byte == 0x5C then -- "/" or "\"
			return string.sub(path, 1, index)
		end
	end

	return ""
end

local here = directory(debug.getinfo(1, "S").source)
local libraryName = jit.os == "Windows" and "stb.dll" or "stb.so"
local libraryPath = here .. libraryName

do
	local probe = io.open(libraryPath, "rb")

	if probe == nil then
		error("The stb codec is missing from " .. here .. ". Run `lde install` to build it from build.lua.")
	end

	probe:close()
end

ffi.cdef([[
	const char *image_reason(void);

	void *image_decode_memory(const char *data, size_t size, int desired_channels);
	void *image_decode_frames_memory(const char *data, size_t size, int desired_channels);
	int image_width(const void *image);
	int image_height(const void *image);
	int image_channels(const void *image);
	int image_pixel_channels(const void *image);
	int image_frame_count(const void *image);
	int image_frame_delay(const void *image, int frame);
	unsigned char *image_pixels(const void *image);
	void image_free(void *image);

	int image_probe_memory(const char *data, size_t size, int *width, int *height, int *channels, int *bits);

	typedef struct image_encode_options {
		int format;
		int width;
		int height;
		int channels;
		int quality;
		int compression;
		int rle;
	} image_encode_options;

	int image_encode(const unsigned char *pixels, const image_encode_options *options, unsigned char **out, unsigned long long *size);
	void image_bytes_free(unsigned char *bytes);
]])

local lib = ffi.load(libraryPath)

---@alias image.native.Handle ffi.cdata*

--- The ids stb_image_write knows each format by. src/formats/stb.lua names them
--- after these, so an encoding format is picked by name and translated here.
---@type table<string, integer>
local writeFormats = {
	png = 1,
	jpg = 2,
	tga = 3,
	bmp = 4,
}

---@class image.native.EncodeOptions
---@field format integer # one of writeFormats
---@field width number
---@field height number
---@field channels number # 1 to 4
---@field quality number? # JPEG, 1 to 100
---@field compression number? # PNG zlib level, 0 to 9
---@field rle boolean? # TGA run length encoding

---@class image.native.Info
---@field width number
---@field height number
---@field channels number
---@field bits number # 8 or 16, the width of the file's samples

local native = {}

native.writeFormats = writeFormats

--- Decodes an image from memory: the first frame only, when it is an animation.
---@param data string
---@param desiredChannels integer? # 1 to 4, or nil to keep the file's own
---@return image.native.Handle? image
---@return string? err
function native.decode(data, desiredChannels)
	local handle = lib.image_decode_memory(data, #data, desiredChannels or 0)

	if handle == nil then
		return nil, ffi.string(lib.image_reason())
	end

	---@cast handle image.native.Handle
	return ffi.gc(handle, lib.image_free)
end

--- Decodes every frame of an animation, and the single frame of anything else.
---@param data string
---@param desiredChannels integer?
---@return image.native.Handle? image
---@return string? err
function native.decodeFrames(data, desiredChannels)
	local handle = lib.image_decode_frames_memory(data, #data, desiredChannels or 0)

	if handle == nil then
		return nil, ffi.string(lib.image_reason())
	end

	---@cast handle image.native.Handle
	return ffi.gc(handle, lib.image_free)
end

--- Releases a handle early, rather than waiting for the collector. Doing this while
--- the handle is still referenced elsewhere leaves those references dangling.
---@param handle image.native.Handle
function native.release(handle)
	-- The finalizer is dropped first, so the collector does not free it twice.
	ffi.gc(handle, nil)
	lib.image_free(handle)
end

--- Reads a header without decoding anything.
---@param data string
---@return image.native.Info? info
---@return string? err
function native.probe(data)
	local width = ffi.new("int[1]")
	local height = ffi.new("int[1]")
	local channels = ffi.new("int[1]")
	local bits = ffi.new("int[1]")

	if lib.image_probe_memory(data, #data, width, height, channels, bits) == 0 then
		return nil, ffi.string(lib.image_reason())
	end

	return {
		width = width[0],
		height = height[0],
		channels = channels[0],
		bits = bits[0],
	}
end

--- What a decoded handle reports.
---@class image.native.Decoded
---@field width number
---@field height number
---@field channels number # the channels the file held
---@field pixelChannels number # the channels the pixel buffer holds
---@field frames number
---@field pixels ffi.cdata* # uint8_t*, owned by the handle

---@param handle image.native.Handle
---@return image.native.Decoded
function native.describe(handle)
	local pixelChannels = lib.image_pixel_channels(handle)

	return {
		width = lib.image_width(handle),
		height = lib.image_height(handle),
		channels = lib.image_channels(handle),
		pixelChannels = pixelChannels,
		frames = lib.image_frame_count(handle),
		pixels = lib.image_pixels(handle),
	}
end

--- Milliseconds to show a frame. Zero when the file does not say.
---@param handle image.native.Handle
---@param frame number # zero based
---@return number
function native.frameDelay(handle, frame)
	return lib.image_frame_delay(handle, frame)
end

--- Encodes pixels into one of the formats stb_image_write knows.
---@param pixels ffi.cdata* # uint8_t*
---@param options image.native.EncodeOptions
---@return string? encoded
---@return string? err
function native.encode(pixels, options)
	local settings = ffi.new("image_encode_options", {
		format = options.format,
		width = options.width,
		height = options.height,
		channels = options.channels,
		quality = options.quality or 0,
		-- A negative asks the encoder for its own default.
		compression = options.compression or -1,
		rle = options.rle == nil and -1 or (options.rle and 1 or 0),
	})

	local out = ffi.new("unsigned char *[1]")
	local size = ffi.new("unsigned long long[1]")

	if lib.image_encode(pixels, settings, out, size) == 0 then
		return nil, ffi.string(lib.image_reason())
	end

	local encoded = ffi.string(out[0], tonumber(size[0]))
	lib.image_bytes_free(out[0])

	return encoded
end

return native
