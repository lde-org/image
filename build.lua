-- Fetches and compiles the stb codec this package reads and writes images with.
--
-- stb_image and stb_image_write are single header libraries, so the repository
-- carries the recipe rather than a copy of them: both are fetched at a pinned
-- commit and compiled together with the shim in src/native into one shared
-- library. lde runs this script again whenever anything under src/ changes, so the
-- headers and the compiled library are cached in the target directory and reused
-- while the recipe stays the same.
local build = require("lde-build")
local bit = require("bit")

-- Bump when the recipe changes in a way the cache key cannot see.
local RECIPE_VERSION = 1

local STB_IMAGE_COMMIT = "013ac3beddff3dbffafd5177e7972067cd2b5083" -- v2.30
local STB_IMAGE_WRITE_COMMIT = "1ee679ca2ef753a528db5ba6801e1067b40481b8" -- v1.16

local CACHE_DIR = "../image-native"
local CACHE_NAME = "image"

local isWindows = jit.os == "Windows"
local isMac = jit.os == "OSX"
-- Windows has two toolchains in the wild: mingw, whose linker is GNU ld, and the
-- clang that targets MSVC, which hands its arguments to lld-link or link.exe and
-- rejects both -fPIC and the GNU linker options.
local isMsvc = build.target:find("msvc", 1, true) ~= nil
local libraryName = isWindows and "stb.dll" or "stb.so"

---@class image.Vendored
---@field name string
---@field file string
---@field commit string

---@type image.Vendored[]
local VENDORED = {
	{ name = "stb_image", file = "stb_image.h", commit = STB_IMAGE_COMMIT },
	{ name = "stb_image_write", file = "stb_image_write.h", commit = STB_IMAGE_WRITE_COMMIT },
}

--- What Lua calls through ffi.load. An MSVC linked DLL exports nothing on its own,
--- and its linker takes no wildcards, so the names are listed. Keeping this in step
--- with the bindings is the same obligation the ELF version script has.
local EXPORTED = {
	"image_bytes_free",
	"image_channels",
	"image_decode_frames_memory",
	"image_decode_memory",
	"image_encode",
	"image_frame_count",
	"image_frame_delay",
	"image_free",
	"image_height",
	"image_pixel_channels",
	"image_pixels",
	"image_probe_memory",
	"image_reason",
	"image_stream_close",
	"image_stream_next",
	"image_stream_open",
	"image_stream_rewind",
	"image_width",
}

--- djb2, so any change to the recipe parts below builds a fresh library. A plain
--- FNV-1a multiply would lose precision in a Lua double.
---@param text string
local function hash(text)
	local value = 5381

	for i = 1, #text do
		value = bit.band(value * 33 + text:byte(i), 0xffffffff)
	end

	return string.format("%08x", value)
end

---@param entry image.Vendored
local function fetch(entry)
	if build:exists(CACHE_DIR .. "/" .. entry.file) then
		return
	end

	local url = string.format(
		"https://raw.githubusercontent.com/nothings/stb/%s/%s", entry.commit, entry.file)

	build:write(CACHE_DIR .. "/" .. entry.file, build:fetch(url))
end

local shim = build:read("native/stb.c")
local cacheKey = table.concat({
	RECIPE_VERSION,
	STB_IMAGE_COMMIT,
	STB_IMAGE_WRITE_COMMIT,
	build.target,
	hash(shim),
}, "-")

local cachedLibrary = string.format("%s/%s-%s-%s", CACHE_DIR, CACHE_NAME, cacheKey, libraryName)

if build:exists(cachedLibrary) then
	build:copy(cachedLibrary, libraryName)
	return
end

for _, entry in ipairs(VENDORED) do
	fetch(entry)
end

-- The headers are only read at build time, so they stay in the cache directory
-- instead of being copied next to the module.
local includes = { "-I" .. CACHE_DIR }

-- Both headers are compiled with the file handling of stb taken out: the package
-- reads a file itself and hands stb memory, so its stdio entry points would be
-- dead weight, and with the version script the linker drops whatever else nothing
-- reaches.
local args = {
	"-c",
	"-O2",
	"-ffunction-sections",
	"-fdata-sections",
	"-DSTBI_NO_STDIO",
	"-DSTBI_WRITE_NO_STDIO",
}

-- Position independent code is only meaningful where the loader needs it, and the
-- MSVC target rejects the option outright.
if not isWindows then
	args[#args + 1] = "-fPIC"
end

for _, include in ipairs(includes) do
	args[#args + 1] = include
end

args[#args + 1] = "native/stb.c"
args[#args + 1] = "-o"
args[#args + 1] = "native/stb.o"

build:cc(args)

-- Only these symbols are called from Lua. Hiding the rest lets the linker drop
-- every stb function that nothing reaches.
local EXPORTS = "{\n\tglobal:\n\t\timage_*;\n\tlocal:\n\t\t*;\n};\n"

build:write("exports.map", EXPORTS)

local linkArgs = {}

if isMac then
	linkArgs[#linkArgs + 1] = "-dynamiclib"
	linkArgs[#linkArgs + 1] = "-Wl,-dead_strip"
else
	linkArgs[#linkArgs + 1] = "-shared"

	if isMsvc then
		-- lld-link and link.exe spell dead code elimination this way, and they need
		-- to be told what to export.
		local definition = { "EXPORTS" }
		for _, name in ipairs(EXPORTED) do
			definition[#definition + 1] = name
		end

		build:write("exports.def", table.concat(definition, "\n") .. "\n")
		linkArgs[#linkArgs + 1] = "-Wl,/OPT:REF"
		linkArgs[#linkArgs + 1] = "-Wl,/DEF:exports.def"
	else
		linkArgs[#linkArgs + 1] = "-Wl,--gc-sections"
	end

	-- Windows fails on undefined symbols anyway; ELF hides them until a call
	-- crashes, which would turn a missing source file into a runtime fault.
	if not isWindows then
		linkArgs[#linkArgs + 1] = "-Wl,--no-undefined"

		-- A version script is ELF's way of saying what a shared library exports.
		-- macOS would need -exported_symbols_list and Windows a .def file.
		linkArgs[#linkArgs + 1] = "-Wl,--version-script=exports.map"
	end
end

linkArgs[#linkArgs + 1] = "-o"
linkArgs[#linkArgs + 1] = libraryName
linkArgs[#linkArgs + 1] = "native/stb.o"

-- MSVC has no separate math library to link against.
if not isWindows then
	linkArgs[#linkArgs + 1] = "-lm"
end

build:cc(linkArgs)

build:delete("native/stb.o")
build:delete("exports.map")
if isMsvc then
	build:delete("exports.def")
end

if not build:exists(libraryName) then
	error("stb_image did not link into " .. libraryName)
end

build:copy(libraryName, cachedLibrary)
