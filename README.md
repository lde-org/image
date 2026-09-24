# image

Image encoding and decoding library.

## Usage

```bash
lde add image
```

## Support

The following file formats are supported:

- PNG, JPEG, TGA, BMP, PSD, GIF, HDR, PIC, PNM (from `stb_image`)
- QOI, PPM

PNG, JPEG, TGA, BMP, QOI, PPM and PGM are written as well as read; a GIF, PSD, HDR or
PIC has to be written by something else. A GIF comes back with every frame of the
animation in it, each with the time it is shown for.

## Loading and saving

```lua
local image = require("image")

local photo = assert(image.load("photo.png"))
print(photo.width, photo.height, photo.channels)

local r, g, b, a = photo:getPixel(0, 0)
photo:setPixel(0, 0, 255, 0, 0)

assert(photo:save("touched.jpg", { quality = 95 }))
```

The format to write comes from the extension, or from a name given to `encode`:

```lua
local bytes = assert(photo:encode("qoi"))
```

`load` and `loadFrames` take a path; `decode`, `decodeFrames` and `probe` take the
bytes of a file. `probe` reads a header without decoding any pixels, which is what a
caller wants before it commits to the whole image:

```lua
local file = assert(io.open("photo.png", "rb"))
local bytes = file:read("*a")
file:close()

local info = assert(image.probe(bytes))
print(info.format.name, info.width, info.height, info.channels, info.bits)

if info.width * info.height < 4096 * 4096 then
	local photo = assert(image.decode(bytes))
end
```

An image is a shape and an ffi buffer, so the pixels go anywhere an
`unsigned char *` can:

```lua
local canvas = image.new(512, 512, 4)
canvas:fill(0, 0, 0, 255)

canvas:flip()      -- for a texture that is read bottom row first
canvas:convert(3)  -- a copy, without the alpha
canvas.pixels      -- uint8_t*, width * height * channels bytes
```

## Animations

`loadFrames` decodes every frame of an animation, and the one frame of anything else,
as an `image.Animation`:

```lua
local animation = assert(image.loadFrames("dance.gif"))

print(animation.width, animation.height, #animation.frames, animation:duration())

for index, frame in ipairs(animation.frames) do
	print(index, frame.delay, frame:getPixel(0, 0))
	assert(frame:save(string.format("frame-%02d.png", index)))
end

animation:close() -- every frame points into one buffer, which this releases
```

## Examples

| Example                       | What it does                                           |
| ----------------------------- | ------------------------------------------------------ |
| [canvas](./examples/canvas)   | Draws a gradient and a checkerboard, saves three files |
| [inspect](./examples/inspect) | Reports the format, size and frames of a file          |
| [convert](./examples/convert) | Writes a file out as another format                    |

Each one is an lde package of its own:

```bash
ldx canvas --git https://github.com/bycruz/image
```

Or from a checkout, inside one of them:

```bash
cd examples/canvas && lde run
cd examples/inspect && lde run -- path/to/photo.png
```

## Building

`stb_image` and `stb_image_write` are single header libraries, so `build.lua` fetches
both at a pinned commit and compiles them, together with the shim in `src/native`,
into one shared library. lde needs a C compiler on the PATH to install this package.

## Tests

```bash
lde test
```

The tests lay out the bytes of most formats by hand, from each specification, so a
decoder is checked against a writer that shares none of its code. The three fixtures
kept as files are the formats this package cannot write: one JPEG and two GIFs. See
[ATTRIBUTIONS.md](./ATTRIBUTIONS.md) for where those came from.
