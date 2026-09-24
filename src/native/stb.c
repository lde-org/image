/* The C surface the image package keeps over stb_image and stb_image_write.
 *
 * Both are single header libraries, and this is the one translation unit that
 * carries their implementations. Lua gets three things out of it: an opaque handle
 * over a decoded image, a probe that reads a header without decoding anything, and
 * an encoder that writes into a buffer the caller owns afterwards.
 *
 * The pixels of a decode belong to the handle that stb allocated them in, so
 * image_free is all Lua has to call; nothing else about the pixel buffer is Lua's
 * to manage. Encoding goes the other way around: the buffer the encoder grew is
 * handed to Lua, which copies it out and releases it with image_bytes_free.
 */

#include <limits.h>
#include <stdlib.h>
#include <string.h>

#define STB_IMAGE_IMPLEMENTATION
#define STB_IMAGE_WRITE_IMPLEMENTATION
#include "stb_image.h"
#include "stb_image_write.h"

/* Mirrored by the write formats in src/formats/stb.lua. */
enum {
	IMAGE_FORMAT_PNG = 1,
	IMAGE_FORMAT_JPEG = 2,
	IMAGE_FORMAT_TGA = 3,
	IMAGE_FORMAT_BMP = 4
};

typedef struct image_decoded {
	unsigned char* pixels;
	int width;
	int height;
	/* The channels the file held, before anything was asked of the decoder. */
	int channels;
	/* The channels the pixel buffer holds. */
	int pixelChannels;
	/* Frames the buffer holds: every frame of a GIF, stacked one after another,
	 * and one for everything else. */
	int frames;
	/* Milliseconds to show each frame, and NULL when there is only one. */
	int* delays;
} image_decoded;

typedef struct image_encode_options {
	int format;
	int width;
	int height;
	int channels;
	/* JPEG quality, 1 to 100. Zero asks for the encoder's default. */
	int quality;
	/* PNG zlib level, 0 to 9. Negative asks for the encoder's default. */
	int compression;
	/* TGA run length encoding, 0 or 1. Negative asks for the encoder's default. */
	int rle;
} image_encode_options;

/* What image_reason reports when this shim turned the call down, rather than stb
 * failing on the data. Without it, a refusal would be described by whatever the
 * last decode of an unrelated image happened to fail on. */
static const char* image_shimReason = NULL;

const char* image_reason(void)
{
	if (image_shimReason != NULL) {
		return image_shimReason;
	}

	const char* reason = stbi_failure_reason();

	return reason != NULL ? reason : "unknown error";
}

/* stb takes lengths as ints, so a buffer longer than one can describe is refused
 * rather than truncated. */
static int image_size_ok(size_t size)
{
	return size > 0 && size <= (size_t)INT_MAX;
}

static int image_request_ok(const void* data, size_t size, int desiredChannels)
{
	image_shimReason = NULL;

	if (data == NULL || size == 0) {
		image_shimReason = "the image data is empty";
		return 0;
	}

	if (!image_size_ok(size)) {
		image_shimReason = "the image data is longer than a decoder can be asked for";
		return 0;
	}

	if (desiredChannels < 0 || desiredChannels > 4) {
		image_shimReason = "a decoder takes between 1 and 4 channels, or none to keep the file's own";
		return 0;
	}

	return 1;
}

static void* image_wrap(unsigned char* pixels, int width, int height, int channels, int pixelChannels,
	int frames, int* delays)
{
	image_decoded* image = malloc(sizeof(image_decoded));

	if (image == NULL) {
		stbi_image_free(pixels);
		free(delays);
		return NULL;
	}

	image->pixels = pixels;
	image->width = width;
	image->height = height;
	image->channels = channels;
	image->pixelChannels = pixelChannels;
	image->frames = frames;
	image->delays = delays;

	return image;
}

void* image_decode_memory(const void* data, size_t size, int desiredChannels)
{
	if (!image_request_ok(data, size, desiredChannels)) {
		return NULL;
	}

	int width = 0;
	int height = 0;
	int channels = 0;

	unsigned char* pixels = stbi_load_from_memory(
		(const stbi_uc*)data, (int)size, &width, &height, &channels, desiredChannels);

	if (pixels == NULL) {
		return NULL;
	}

	if (width <= 0 || height <= 0) {
		stbi_image_free(pixels);
		image_shimReason = "the image states no size";

		return NULL;
	}

	return image_wrap(pixels, width, height, channels, desiredChannels > 0 ? desiredChannels : channels, 1, NULL);
}

/* A GIF is the one format stb reads as a stack of frames, and it is the only one
 * that has to be recognized here first: the animated entry point refuses
 * everything else. Anything that is not a GIF takes the still path, so a caller
 * can ask a file for its frames without knowing what it is holding.
 */
static int image_is_gif(const unsigned char* data, size_t size)
{
	return size >= 6 && memcmp(data, "GIF8", 4) == 0 && (data[4] == '7' || data[4] == '9') && data[5] == 'a';
}

void* image_decode_frames_memory(const void* data, size_t size, int desiredChannels)
{
	if (!image_request_ok(data, size, desiredChannels)) {
		return NULL;
	}

	if (!image_is_gif((const unsigned char*)data, size)) {
		return image_decode_memory(data, size, desiredChannels);
	}

	int width = 0;
	int height = 0;
	int frames = 1;
	int channels = 0;
	int* delays = NULL;

	unsigned char* pixels = stbi_load_gif_from_memory(
		(const stbi_uc*)data, (int)size, &delays, &width, &height, &frames, &channels, desiredChannels);

	if (pixels == NULL) {
		free(delays);
		return NULL;
	}

	/* A GIF whose header parses but which holds no image at all comes back as a
	 * zero layer buffer, which is a failed decode rather than an animation of
	 * nothing. */
	if (frames <= 0 || width <= 0 || height <= 0) {
		stbi_image_free(pixels);
		free(delays);
		image_shimReason = "the GIF holds no frames";

		return NULL;
	}

	/* The GIF loader always composites into four channels and says so, whatever
	 * the palette of the file held. */
	return image_wrap(pixels, width, height, channels, desiredChannels > 0 ? desiredChannels : channels,
		frames, delays);
}

int image_width(const void* image)
{
	return ((const image_decoded*)image)->width;
}

int image_height(const void* image)
{
	return ((const image_decoded*)image)->height;
}

int image_channels(const void* image)
{
	return ((const image_decoded*)image)->channels;
}

int image_pixel_channels(const void* image)
{
	return ((const image_decoded*)image)->pixelChannels;
}

int image_frame_count(const void* image)
{
	return ((const image_decoded*)image)->frames;
}

/* Milliseconds to show a frame. Zero when the file does not say. */
int image_frame_delay(const void* image, int frame)
{
	const image_decoded* decoded = image;

	if (decoded->delays == NULL || frame < 0 || frame >= decoded->frames) {
		return 0;
	}

	return decoded->delays[frame];
}

/* Deliberately not const: Lua writes the pixels of a decoded image in place. */
unsigned char* image_pixels(const void* image)
{
	return ((const image_decoded*)image)->pixels;
}

void image_free(void* image)
{
	image_decoded* decoded = image;

	if (decoded == NULL) {
		return;
	}

	stbi_image_free(decoded->pixels);
	free(decoded->delays);
	free(decoded);
}

/* Reads a header without decoding. Bits is 16 for the formats whose samples are
 * wider than a byte, which stb hands out narrowed to eight.
 */
int image_probe_memory(const void* data, size_t size, int* width, int* height, int* channels, int* bits)
{
	image_shimReason = NULL;

	if (data == NULL || size == 0) {
		image_shimReason = "the image data is empty";

		return 0;
	}

	if (!image_size_ok(size)) {
		image_shimReason = "the image data is longer than a decoder can be asked for";

		return 0;
	}

	if (stbi_info_from_memory((const stbi_uc*)data, (int)size, width, height, channels) == 0) {
		return 0;
	}

	*bits = stbi_is_16_bit_from_memory((const stbi_uc*)data, (int)size) ? 16 : 8;

	return 1;
}

typedef struct image_buffer {
	unsigned char* data;
	size_t size;
	size_t capacity;
	int failed;
} image_buffer;

static void image_buffer_append(void* context, void* data, int size)
{
	image_buffer* buffer = context;

	if (size <= 0) {
		return;
	}

	size_t needed = buffer->size + (size_t)size;

	if (needed > buffer->capacity) {
		/* Doubling keeps a whole image to a handful of reallocations. */
		size_t grown = buffer->capacity > 0 ? buffer->capacity : 4096;

		while (grown < needed) {
			grown *= 2;
		}

		unsigned char* block = realloc(buffer->data, grown);
		if (block == NULL) {
			buffer->failed = 1;
			return;
		}

		buffer->data = block;
		buffer->capacity = grown;
	}

	memcpy(buffer->data + buffer->size, data, (size_t)size);
	buffer->size = needed;
}

/* Returns 1 and hands out a buffer the caller frees with image_bytes_free, or 0
 * when the encoder refused the pixels.
 */
int image_encode(const unsigned char* pixels, const image_encode_options* options, unsigned char** out, unsigned long long* size)
{
	image_shimReason = NULL;

	if (pixels == NULL || options == NULL || out == NULL || size == NULL) {
		image_shimReason = "the encoder was handed no pixels";

		return 0;
	}

	if (options->width <= 0 || options->height <= 0) {
		image_shimReason = "the encoder was handed a size of nothing";

		return 0;
	}

	if (options->channels <= 0 || options->channels > 4) {
		image_shimReason = "the encoder takes between 1 and 4 channels";

		return 0;
	}

	/* The encoder settings are globals in stb_image_write, so they are set for the
	 * call and put back afterwards. */
	int compression = stbi_write_png_compression_level;
	int rle = stbi_write_tga_with_rle;

	if (options->compression >= 0) {
		stbi_write_png_compression_level = options->compression;
	}

	if (options->rle >= 0) {
		stbi_write_tga_with_rle = options->rle;
	}

	image_buffer buffer = { 0 };
	int written = 0;

	switch (options->format) {
		case IMAGE_FORMAT_PNG:
			written = stbi_write_png_to_func(image_buffer_append, &buffer, options->width, options->height,
				options->channels, pixels, options->width * options->channels);
			break;
		case IMAGE_FORMAT_JPEG:
			written = stbi_write_jpg_to_func(image_buffer_append, &buffer, options->width, options->height,
				options->channels, pixels, options->quality);
			break;
		case IMAGE_FORMAT_TGA:
			written = stbi_write_tga_to_func(image_buffer_append, &buffer, options->width, options->height,
				options->channels, pixels);
			break;
		case IMAGE_FORMAT_BMP:
			written = stbi_write_bmp_to_func(image_buffer_append, &buffer, options->width, options->height,
				options->channels, pixels);
			break;
		default:
			break;
	}

	stbi_write_png_compression_level = compression;
	stbi_write_tga_with_rle = rle;

	if (!written || buffer.failed || buffer.data == NULL) {
		free(buffer.data);

		if (buffer.failed) {
			image_shimReason = "the encoder ran out of memory";
		} else if (image_shimReason == NULL) {
			image_shimReason = "the encoder refused these pixels, which are the wrong shape or depth for it";
		}

		return 0;
	}

	*out = buffer.data;
	*size = (unsigned long long)buffer.size;

	return 1;
}

void image_bytes_free(unsigned char* bytes)
{
	free(bytes);
}
