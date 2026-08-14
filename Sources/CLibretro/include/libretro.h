/*
 * libretro.h — trimmed but ABI-correct subset of the canonical libretro API
 * (https://github.com/libretro/libretro-common/blob/master/include/libretro.h).
 *
 * ⚠️ ABI CRITICAL: struct field order/types and enum values must match the
 * canonical header exactly. libretro cores are compiled against the canonical
 * layout; any divergence here corrupts memory. Do not "modernize" anything.
 *
 * Only the subset used by GameDock's software-render frontend is included.
 * The canonical header is ~1900 lines; we keep the pieces we ship with,
 * plus harmless declarations needed by the C shim (shim.c).
 */
#ifndef LIBRETRO_H__
#define LIBRETRO_H__

#include <stddef.h>
#include <stdint.h>
#include <stdbool.h>
#include <stdarg.h>

#ifdef __cplusplus
extern "C" {
#endif

#ifndef RETRO_CALLCONV
#define RETRO_CALLCONV
#endif

/* Libretro API version */
#define RETRO_API_VERSION 1

/* ------------------------------------------------------------------ */
/* Device types (RETRO_DEVICE_*)                                      */
/* ------------------------------------------------------------------ */
#define RETRO_DEVICE_NONE        0
#define RETRO_DEVICE_JOYPAD      1
#define RETRO_DEVICE_MOUSE       2
#define RETRO_DEVICE_KEYBOARD    3
#define RETRO_DEVICE_LIGHTGUN    4
#define RETRO_DEVICE_ANALOG      5
#define RETRO_DEVICE_POINTER     6

/* Joypad button ids (RETRO_DEVICE_ID_JOYPAD_*) */
#define RETRO_DEVICE_ID_JOYPAD_B       0
#define RETRO_DEVICE_ID_JOYPAD_Y       1
#define RETRO_DEVICE_ID_JOYPAD_SELECT  2
#define RETRO_DEVICE_ID_JOYPAD_START   3
#define RETRO_DEVICE_ID_JOYPAD_UP      4
#define RETRO_DEVICE_ID_JOYPAD_DOWN    5
#define RETRO_DEVICE_ID_JOYPAD_LEFT    6
#define RETRO_DEVICE_ID_JOYPAD_RIGHT   7
#define RETRO_DEVICE_ID_JOYPAD_A       8
#define RETRO_DEVICE_ID_JOYPAD_X       9
#define RETRO_DEVICE_ID_JOYPAD_L      10
#define RETRO_DEVICE_ID_JOYPAD_R      11
#define RETRO_DEVICE_ID_JOYPAD_L2     12
#define RETRO_DEVICE_ID_JOYPAD_R2     13
#define RETRO_DEVICE_ID_JOYPAD_L3     14
#define RETRO_DEVICE_ID_JOYPAD_R3     15

/* Analog (RETRO_DEVICE_ANALOG) */
#define RETRO_DEVICE_INDEX_ANALOG_LEFT   0
#define RETRO_DEVICE_INDEX_ANALOG_RIGHT  1
#define RETRO_DEVICE_ID_ANALOG_X         0
#define RETRO_DEVICE_ID_ANALOG_Y         1

/* Pixel formats (RETRO_PIXEL_FORMAT_*) */
#define RETRO_PIXEL_FORMAT_0RGB1555 0
#define RETRO_PIXEL_FORMAT_XRGB8888 1
#define RETRO_PIXEL_FORMAT_RGB565   2

/* Memory types (RETRO_MEMORY_*) */
#define RETRO_MEMORY_SAVE_RAM   0
#define RETRO_MEMORY_RTC        1
#define RETRO_MEMORY_SYSTEM_RAM 2
#define RETRO_MEMORY_VIDEO_RAM  3

/* Languages (RETRO_LANGUAGE_*) */
#define RETRO_LANGUAGE_ENGLISH     0
#define RETRO_LANGUAGE_JAPANESE    1
#define RETRO_LANGUAGE_FRENCH      2
#define RETRO_LANGUAGE_SPANISH     3
#define RETRO_LANGUAGE_GERMAN      4
#define RETRO_LANGUAGE_ITALIAN     5
#define RETRO_LANGUAGE_DUTCH       6
#define RETRO_LANGUAGE_PORTUGUESE  7
#define RETRO_LANGUAGE_RUSSIAN     8
#define RETRO_LANGUAGE_KOREAN      9
#define RETRO_LANGUAGE_CHINESE_TRADITIONAL 10
#define RETRO_LANGUAGE_CHINESE_SIMPLIFIED  11

/* ------------------------------------------------------------------ */
/* Log levels                                                          */
/* ------------------------------------------------------------------ */
enum retro_log_level
{
   RETRO_LOG_DEBUG = 0,
   RETRO_LOG_INFO,
   RETRO_LOG_WARN,
   RETRO_LOG_ERROR
};

/* ------------------------------------------------------------------ */
/* Environment commands (RETRO_ENVIRONMENT_*) — canonical values,       */
/* verified against libretro-common/libretro.h. Experimental commands   */
/* carry the 0x10000 bit. Do NOT renumber.                              */
/* ------------------------------------------------------------------ */
enum retro_environment_cmd
{
   RETRO_ENVIRONMENT_SET_ROTATION = 1,
   RETRO_ENVIRONMENT_GET_OVERSCAN = 2,
   RETRO_ENVIRONMENT_GET_CAN_DUPE = 3,
   RETRO_ENVIRONMENT_SET_MESSAGE = 6,
   RETRO_ENVIRONMENT_SHUTDOWN = 7,
   RETRO_ENVIRONMENT_SET_PERFORMANCE_LEVEL = 8,
   RETRO_ENVIRONMENT_GET_SYSTEM_DIRECTORY = 9,
   RETRO_ENVIRONMENT_SET_PIXEL_FORMAT = 10,
   RETRO_ENVIRONMENT_SET_INPUT_DESCRIPTORS = 11,
   RETRO_ENVIRONMENT_SET_KEYBOARD_CALLBACK = 12,
   RETRO_ENVIRONMENT_SET_DISK_CONTROL_INTERFACE = 13,
   RETRO_ENVIRONMENT_SET_HW_RENDER = 14,
   RETRO_ENVIRONMENT_GET_VARIABLE = 15,
   RETRO_ENVIRONMENT_SET_VARIABLES = 16,
   RETRO_ENVIRONMENT_GET_VARIABLE_UPDATE = 17,
   RETRO_ENVIRONMENT_SET_SUPPORT_NO_GAME = 18,
   RETRO_ENVIRONMENT_GET_LIBRETRO_PATH = 19,
   RETRO_ENVIRONMENT_SET_FRAME_TIME_CALLBACK = 21,
   RETRO_ENVIRONMENT_SET_AUDIO_CALLBACK = 22,
   RETRO_ENVIRONMENT_GET_RUMBLE_INTERFACE = 23,
   RETRO_ENVIRONMENT_GET_INPUT_DEVICE_CAPABILITIES = 24,
   RETRO_ENVIRONMENT_GET_SENSOR_INTERFACE = (25 | 0x10000),
   RETRO_ENVIRONMENT_GET_CAMERA_INTERFACE = (26 | 0x10000),
   RETRO_ENVIRONMENT_GET_LOG_INTERFACE = 27,
   RETRO_ENVIRONMENT_GET_PERF_INTERFACE = 28,
   RETRO_ENVIRONMENT_GET_LOCATION_INTERFACE = 29,
   RETRO_ENVIRONMENT_GET_CONTENT_DIRECTORY = 30,
   RETRO_ENVIRONMENT_GET_CORE_ASSETS_DIRECTORY = 30,
   RETRO_ENVIRONMENT_GET_SAVE_DIRECTORY = 31,
   RETRO_ENVIRONMENT_SET_SYSTEM_AV_INFO = 32,
   RETRO_ENVIRONMENT_SET_PROC_ADDRESS_CALLBACK = 33,
   RETRO_ENVIRONMENT_SET_SUBSYSTEM_INFO = 34,
   RETRO_ENVIRONMENT_SET_CONTROLLER_INFO = 35,
   RETRO_ENVIRONMENT_SET_MEMORY_MAPS = (36 | 0x10000),
   RETRO_ENVIRONMENT_SET_GEOMETRY = 37,
   RETRO_ENVIRONMENT_GET_USERNAME = 38,
   RETRO_ENVIRONMENT_GET_LANGUAGE = 39,
   RETRO_ENVIRONMENT_GET_CURRENT_SOFTWARE_FRAMEBUFFER = (40 | 0x10000),
   RETRO_ENVIRONMENT_GET_HW_RENDER_INTERFACE = (41 | 0x10000),
   RETRO_ENVIRONMENT_SET_SUPPORT_ACHIEVEMENTS = (42 | 0x10000),
   RETRO_ENVIRONMENT_SET_HW_RENDER_CONTEXT_NEGOTIATION_INTERFACE = (43 | 0x10000),
   RETRO_ENVIRONMENT_SET_HW_SHARED_CONTEXT = (44 | 0x10000),
   RETRO_ENVIRONMENT_GET_VFS_INTERFACE = (45 | 0x10000),
   RETRO_ENVIRONMENT_GET_LED_INTERFACE = (46 | 0x10000),
   RETRO_ENVIRONMENT_GET_AUDIO_VIDEO_ENABLE = (47 | 0x10000),
   RETRO_ENVIRONMENT_GET_MIDI_INTERFACE = (48 | 0x10000),
   RETRO_ENVIRONMENT_GET_FASTFORWARDING = (49 | 0x10000),
   RETRO_ENVIRONMENT_GET_TARGET_REFRESH_RATE = (50 | 0x10000),
   RETRO_ENVIRONMENT_GET_INPUT_BITMASKS = (51 | 0x10000),
   RETRO_ENVIRONMENT_GET_CORE_OPTIONS_VERSION = 52,
   RETRO_ENVIRONMENT_SET_CORE_OPTIONS = 53,
   RETRO_ENVIRONMENT_SET_CORE_OPTIONS_INTL = 54,
   RETRO_ENVIRONMENT_SET_CORE_OPTIONS_DISPLAY = 55,
   RETRO_ENVIRONMENT_GET_PREFERRED_HW_RENDER = 56,
   RETRO_ENVIRONMENT_GET_DISK_CONTROL_INTERFACE_VERSION = 57,
   RETRO_ENVIRONMENT_SET_DISK_CONTROL_EXT_INTERFACE = 58,
   RETRO_ENVIRONMENT_GET_MESSAGE_INTERFACE_VERSION = 59,
   RETRO_ENVIRONMENT_SET_MESSAGE_EXT = 60,
   RETRO_ENVIRONMENT_GET_INPUT_MAX_USERS = 61,
   RETRO_ENVIRONMENT_SET_AUDIO_BUFFER_STATUS_CALLBACK = 62,
   RETRO_ENVIRONMENT_SET_MINIMUM_AUDIO_LATENCY = 63,
   RETRO_ENVIRONMENT_SET_FASTFORWARDING_OVERRIDE = 64,
   RETRO_ENVIRONMENT_SET_CONTENT_INFO_OVERRIDE = 65,
   RETRO_ENVIRONMENT_GET_GAME_INFO_EXT = 66,
   RETRO_ENVIRONMENT_SET_CORE_OPTIONS_V2 = 67,
   RETRO_ENVIRONMENT_SET_CORE_OPTIONS_V2_INTL = 68,
   RETRO_ENVIRONMENT_SET_CORE_OPTIONS_UPDATE_DISPLAY_CALLBACK = 69,
   RETRO_ENVIRONMENT_SET_VARIABLE = 70,
   RETRO_ENVIRONMENT_GET_THROTTLE_STATE = (71 | 0x10000),
   RETRO_ENVIRONMENT_GET_SAVESTATE_CONTEXT = (72 | 0x10000),
   RETRO_ENVIRONMENT_GET_HW_RENDER_CONTEXT_NEGOTIATION_INTERFACE_SUPPORT = (73 | 0x10000),
   RETRO_ENVIRONMENT_GET_JIT_CAPABLE = 74,
   RETRO_ENVIRONMENT_GET_MICROPHONE_INTERFACE = (75 | 0x10000),
   RETRO_ENVIRONMENT_GET_DEVICE_POWER = (77 | 0x10000),
   RETRO_ENVIRONMENT_SET_NETPACKET_INTERFACE = 78,
   RETRO_ENVIRONMENT_GET_PLAYLIST_DIRECTORY = 79,
   RETRO_ENVIRONMENT_GET_FILE_BROWSER_START_DIRECTORY = 80,
   RETRO_ENVIRONMENT_EXEC_MEM_ALLOC = 83,
   RETRO_ENVIRONMENT_EXEC_MEM_FREE = 84,
   RETRO_ENVIRONMENT_SET_SERIALIZATION_QUIRKS = 87
};

/* ------------------------------------------------------------------ */
/* Data structures — canonical layout                                  */
/* ------------------------------------------------------------------ */
struct retro_game_info
{
   const char *path;
   const void *data;
   size_t size;
   const char *meta;
};

struct retro_system_info
{
   const char *library_name;
   const char *library_version;
   const char *valid_extensions;
   bool need_fullpath;
   bool block_extract;
};

struct retro_game_geometry
{
   unsigned base_width;
   unsigned base_height;
   unsigned max_width;
   unsigned max_height;
   float aspect_ratio;
};

struct retro_system_timing
{
   double fps;
   double sample_rate;
};

struct retro_system_av_info
{
   struct retro_game_geometry geometry;
   struct retro_system_timing timing;
};

struct retro_variable
{
   const char *key;
   const char *value;
};

struct retro_message
{
   const char *msg;
   unsigned frames;
};

typedef void (RETRO_CALLCONV *retro_log_printf_t)(enum retro_log_level level, const char *fmt, ...);
struct retro_log_callback
{
   retro_log_printf_t log;
};

struct retro_audio_callback
{
   void (*callback)(void);
   void (*set_state)(bool enabled);
};

/* ------------------------------------------------------------------ */
/* Callback typedefs                                                   */
/* ------------------------------------------------------------------ */
typedef bool (RETRO_CALLCONV *retro_environment_t)(unsigned cmd, void *data);
typedef void (RETRO_CALLCONV *retro_video_refresh_t)(const void *data, unsigned width, unsigned height, size_t pitch);
typedef void (RETRO_CALLCONV *retro_audio_sample_t)(int16_t left, int16_t right);
typedef size_t (RETRO_CALLCONV *retro_audio_sample_batch_t)(const int16_t *data, size_t frames);
typedef void (RETRO_CALLCONV *retro_input_poll_t)(void);
typedef int16_t (RETRO_CALLCONV *retro_input_state_t)(unsigned port, unsigned device, unsigned index, unsigned id);

/* ------------------------------------------------------------------ */
/* Core API function typedefs (for dlsym casting in Swift)             */
/* ------------------------------------------------------------------ */
typedef void (RETRO_CALLCONV *retro_set_environment_t)(retro_environment_t);
typedef void (RETRO_CALLCONV *retro_set_video_refresh_t)(retro_video_refresh_t);
typedef void (RETRO_CALLCONV *retro_set_audio_sample_t)(retro_audio_sample_t);
typedef void (RETRO_CALLCONV *retro_set_audio_sample_batch_t)(retro_audio_sample_batch_t);
typedef void (RETRO_CALLCONV *retro_set_input_poll_t)(retro_input_poll_t);
typedef void (RETRO_CALLCONV *retro_set_input_state_t)(retro_input_state_t);
typedef void (RETRO_CALLCONV *retro_init_t)(void);
typedef void (RETRO_CALLCONV *retro_deinit_t)(void);
typedef unsigned (RETRO_CALLCONV *retro_api_version_t)(void);
typedef void (RETRO_CALLCONV *retro_get_system_info_t)(struct retro_system_info *);
typedef void (RETRO_CALLCONV *retro_get_system_av_info_t)(struct retro_system_av_info *);
typedef void (RETRO_CALLCONV *retro_set_controller_port_device_t)(unsigned port, unsigned device);
typedef void (RETRO_CALLCONV *retro_reset_t)(void);
typedef void (RETRO_CALLCONV *retro_run_t)(void);
typedef bool (RETRO_CALLCONV *retro_load_game_t)(const struct retro_game_info *);
typedef bool (RETRO_CALLCONV *retro_load_game_special_t)(unsigned game_type, const struct retro_game_info *, size_t num_info);
typedef void (RETRO_CALLCONV *retro_unload_game_t)(void);
typedef unsigned (RETRO_CALLCONV *retro_get_region_t)(void);
typedef void * (RETRO_CALLCONV *retro_get_memory_data_t)(unsigned id);
typedef size_t (RETRO_CALLCONV *retro_get_memory_size_t)(unsigned id);

/* ------------------------------------------------------------------ */
/* Hardware render (RETRO_ENVIRONMENT_SET_HW_RENDER = 14)               */
/* ------------------------------------------------------------------ */
enum retro_hw_context_type
{
   RETRO_HW_CONTEXT_NONE = 0,
   RETRO_HW_CONTEXT_OPENGL = 1,
   RETRO_HW_CONTEXT_OPENGLES2 = 2,
   RETRO_HW_CONTEXT_OPENGL_CORE = 3,
   RETRO_HW_CONTEXT_OPENGLES3 = 4,
   RETRO_HW_CONTEXT_OPENGLES_VERSION = 5,
   RETRO_HW_CONTEXT_VULKAN = 6,
   RETRO_HW_CONTEXT_D3D11 = 7,
   RETRO_HW_CONTEXT_D3D10 = 8,
   RETRO_HW_CONTEXT_D3D12 = 9,
   RETRO_HW_CONTEXT_D3D9 = 10
};

typedef void (RETRO_CALLCONV *retro_hw_context_reset_t)(void);
typedef void (RETRO_CALLCONV *retro_hw_context_destroy_t)(void);
typedef uintptr_t (RETRO_CALLCONV *retro_hw_get_current_framebuffer_t)(void);
typedef void (RETRO_CALLCONV *retro_proc_address_t)(void);
typedef retro_proc_address_t (RETRO_CALLCONV *retro_hw_get_proc_address_t)(const char *sym);

struct retro_hw_render_callback
{
   enum retro_hw_context_type context_type;
   retro_hw_context_reset_t context_reset;
   retro_hw_get_current_framebuffer_t get_current_framebuffer;
   retro_hw_get_proc_address_t get_proc_address;
   bool depth;
   bool stencil;
   bool bottom_left_origin;
   unsigned version_major;
   unsigned version_minor;
   bool cache_context;
   retro_hw_context_destroy_t context_destroy;
   bool debug_context;
};

/* ------------------------------------------------------------------ */
/* Core API (implemented by cores; shim.c links against these)         */
/* ------------------------------------------------------------------ */
void retro_set_environment(retro_environment_t);
void retro_set_video_refresh(retro_video_refresh_t);
void retro_set_audio_sample(retro_audio_sample_t);
void retro_set_audio_sample_batch(retro_audio_sample_batch_t);
void retro_set_input_poll(retro_input_poll_t);
void retro_set_input_state(retro_input_state_t);
void retro_init(void);
void retro_deinit(void);
unsigned retro_api_version(void);
void retro_get_system_info(struct retro_system_info *info);
void retro_get_system_av_info(struct retro_system_av_info *info);
void retro_set_controller_port_device(unsigned port, unsigned device);
void retro_reset(void);
void retro_run(void);
bool retro_load_game(const struct retro_game_info *game);
bool retro_load_game_special(unsigned game_type, const struct retro_game_info *info, size_t num_info);
void retro_unload_game(void);
unsigned retro_get_region(void);
void *retro_get_memory_data(unsigned id);
size_t retro_get_memory_size(unsigned id);

#ifdef __cplusplus
}
#endif

#endif /* LIBRETRO_H__ */
