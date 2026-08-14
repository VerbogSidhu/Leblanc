/*
 * mockcore.c — a self-contained fake libretro core for GameDock's headless
 * end-to-end self-test (make selftest → GameDock --selftest).
 *
 * Self-contained: declares the minimal libretro ABI subset it needs inline
 * (field order/types must match Sources/CLibretro/include/libretro.h exactly).
 *
 * Behavior: draws a 320×240 RGB565 frame with a cyan square that moves right
 * one pixel per frame (extra when dpad RIGHT is held), emits a 440 Hz square
 * wave via retro_audio_sample_batch, and round-trips input state through the
 * frontend's input_state callback.
 */

#include <stdint.h>
#include <stddef.h>
#include <stdbool.h>
#include <string.h>
#include <math.h>

/* --- minimal libretro ABI (mirrors libretro.h exactly) ------------- */
#define RETRO_API_VERSION 1

#define RETRO_DEVICE_JOYPAD 1

#define RETRO_DEVICE_ID_JOYPAD_RIGHT 7

#define RETRO_PIXEL_FORMAT_0RGB1555 0
#define RETRO_PIXEL_FORMAT_XRGB8888 1
#define RETRO_PIXEL_FORMAT_RGB565   2

enum {
   RETRO_ENVIRONMENT_GET_SYSTEM_DIRECTORY = 9,
   RETRO_ENVIRONMENT_SET_PIXEL_FORMAT     = 10,
   RETRO_ENVIRONMENT_SET_SUPPORT_NO_GAME  = 18,
   RETRO_ENVIRONMENT_GET_LOG_INTERFACE    = 27,
};

enum retro_log_level {
   RETRO_LOG_DEBUG = 0,
   RETRO_LOG_INFO,
   RETRO_LOG_WARN,
   RETRO_LOG_ERROR
};

typedef void (*retro_log_printf_t)(enum retro_log_level level, const char *fmt, ...);
struct retro_log_callback {
   retro_log_printf_t log;
};

struct retro_game_info {
   const char *path;
   const void *data;
   size_t size;
   const char *meta;
};

struct retro_system_info {
   const char *library_name;
   const char *library_version;
   const char *valid_extensions;
   bool need_fullpath;
   bool block_extract;
};

struct retro_game_geometry {
   unsigned base_width;
   unsigned base_height;
   unsigned max_width;
   unsigned max_height;
   float aspect_ratio;
};

struct retro_system_timing {
   double fps;
   double sample_rate;
};

struct retro_system_av_info {
   struct retro_game_geometry geometry;
   struct retro_system_timing timing;
};

typedef bool (*retro_environment_t)(unsigned cmd, void *data);
typedef void (*retro_video_refresh_t)(const void *data, unsigned width, unsigned height, size_t pitch);
typedef void (*retro_audio_sample_t)(int16_t left, int16_t right);
typedef size_t (*retro_audio_sample_batch_t)(const int16_t *data, size_t frames);
typedef void (*retro_input_poll_t)(void);
typedef int16_t (*retro_input_state_t)(unsigned port, unsigned device, unsigned index, unsigned id);

/* --- stored frontend callbacks ------------------------------------ */
static retro_environment_t env_cb;
static retro_video_refresh_t video_cb;
static retro_audio_sample_t audio_cb;
static retro_audio_sample_batch_t audio_batch_cb;
static retro_input_poll_t input_poll_cb;
static retro_input_state_t input_state_cb;

/* --- core state ---------------------------------------------------- */
static unsigned square_x = 160;
static unsigned square_y = 120;
static double phase = 0.0;

#define FRAME_W 320
#define FRAME_H 240
#define SQUARE 32

static uint16_t framebuffer[FRAME_W * FRAME_H];

/* --- API version --------------------------------------------------- */
unsigned retro_api_version(void) { return RETRO_API_VERSION; }

/* --- set_* callbacks ----------------------------------------------- */
void retro_set_environment(retro_environment_t cb) { env_cb = cb; }
void retro_set_video_refresh(retro_video_refresh_t cb) { video_cb = cb; }
void retro_set_audio_sample(retro_audio_sample_t cb) { audio_cb = cb; }
void retro_set_audio_sample_batch(retro_audio_sample_batch_t cb) { audio_batch_cb = cb; }
void retro_set_input_poll(retro_input_poll_t cb) { input_poll_cb = cb; }
void retro_set_input_state(retro_input_state_t cb) { input_state_cb = cb; }

/* --- system info --------------------------------------------------- */
void retro_get_system_info(struct retro_system_info *info) {
    info->library_name = "GameDock Mock Core";
    info->library_version = "1.0.0";
    info->valid_extensions = "";
    info->need_fullpath = false;
    info->block_extract = false;
}

void retro_get_system_av_info(struct retro_system_av_info *info) {
    info->geometry.base_width = FRAME_W;
    info->geometry.base_height = FRAME_H;
    info->geometry.max_width = FRAME_W;
    info->geometry.max_height = FRAME_H;
    info->geometry.aspect_ratio = 4.0f / 3.0f;
    info->timing.fps = 60.0;
    info->timing.sample_rate = 44100.0;
}

/* --- lifecycle ----------------------------------------------------- */
void retro_init(void) {
    /* Exercise env plumbing: request the system directory, declare support
       for no-game loading, and (critically) wire GET_LOG_INTERFACE so the
       shim_log_printf → gd_log path is exercised by the selftest. */
    if (env_cb) {
        const char *sysdir = NULL;
        env_cb(RETRO_ENVIRONMENT_GET_SYSTEM_DIRECTORY, &sysdir);

        struct retro_log_callback log_cb;
        memset(&log_cb, 0, sizeof(log_cb));
        if (env_cb(RETRO_ENVIRONMENT_GET_LOG_INTERFACE, &log_cb) && log_cb.log) {
            log_cb.log(RETRO_LOG_INFO, "mockcore init: system dir = %s",
                       sysdir ? sysdir : "(null)");
        }

        bool no_game = true;
        env_cb(RETRO_ENVIRONMENT_SET_SUPPORT_NO_GAME, &no_game);
    }
}

void retro_deinit(void) {}
void retro_reset(void) {}

/* --- game load ----------------------------------------------------- */
bool retro_load_game(const struct retro_game_info *game) {
    /* Request RGB565 so the selftest exercises the RGB565 convert path. */
    if (env_cb) {
        unsigned fmt = RETRO_PIXEL_FORMAT_RGB565;
        env_cb(RETRO_ENVIRONMENT_SET_PIXEL_FORMAT, &fmt);
    }
    return true;
}

bool retro_load_game_special(unsigned game_type, const struct retro_game_info *info, size_t num_info) {
    return false;
}

void retro_unload_game(void) {}

void retro_set_controller_port_device(unsigned port, unsigned device) {}

/* --- run ----------------------------------------------------------- */
void retro_run(void) {
    /* poll input */
    if (input_poll_cb) input_poll_cb();

    /* clear to black */
    memset(framebuffer, 0, sizeof(framebuffer));

    /* input: RIGHT held moves extra */
    int extra = 0;
    if (input_state_cb && input_state_cb(0, RETRO_DEVICE_JOYPAD, 0, RETRO_DEVICE_ID_JOYPAD_RIGHT)) {
        extra += 3; /* extra 3 px/frame when held */
    }
    square_x = (square_x + 1 + extra) % (FRAME_W - SQUARE);

    /* draw cyan square (RGB565: 0x07FF = 00000 111111 11111 = cyan, blue+green) */
    for (unsigned y = 0; y < SQUARE; y++) {
        for (unsigned x = 0; x < SQUARE; x++) {
            unsigned px = (square_x + x) % (FRAME_W - 1);
            unsigned py = (square_y + y) % (FRAME_H - 1);
            framebuffer[py * FRAME_W + px] = 0x07FF;
        }
    }

    /* video refresh: pitch = width * 2 = 640 */
    if (video_cb) video_cb(framebuffer, FRAME_W, FRAME_H, FRAME_W * 2);

    /* audio: 44100/60 ≈ 735 frames of 440 Hz square wave */
    enum { AUDIO_FRAMES = 735 };
    static int16_t audio_buf[2 * AUDIO_FRAMES];
    const double sr = 44100.0;
    const double freq = 440.0;
    for (int i = 0; i < AUDIO_FRAMES; i++) {
        int16_t s = (int16_t)((sin(2.0 * M_PI * freq * phase / sr) >= 0.0) ? 8000 : -8000);
        phase += 1.0;
        audio_buf[2 * i] = s;
        audio_buf[2 * i + 1] = s;
    }
    if (audio_batch_cb) audio_batch_cb(audio_buf, AUDIO_FRAMES);
}

/* --- misc ---------------------------------------------------------- */
unsigned retro_get_region(void) { return 0; }
void *retro_get_memory_data(unsigned id) { return NULL; }
size_t retro_get_memory_size(unsigned id) { return 0; }
