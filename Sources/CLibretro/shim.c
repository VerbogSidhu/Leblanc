/*
 * shim.c — libretro callback trampolines. See shim.h for rationale.
 * Only one emulator session is active at a time (v1), so a single global
 * callback registry is sufficient and matches how libretro itself works.
 */
#include "shim.h"
#include <stdarg.h>
#include <stdio.h>
#include <string.h>
#include <dlfcn.h>

static shim_callbacks_t g_cb;
static int g_installed = 0;

void shim_set_callbacks(shim_callbacks_t cb)
{
   g_cb = cb;
   g_installed = 1;
}

/* --- trampolines (exact libretro signatures) ----------------------- */

static void shim_video(const void *data, unsigned width, unsigned height, size_t pitch)
{
   if (g_cb.video)
      g_cb.video(g_cb.ctx, data, width, height, pitch);
}

static void shim_audio(int16_t left, int16_t right)
{
   if (g_cb.audio)
      g_cb.audio(g_cb.ctx, left, right);
}

static size_t shim_audio_batch(const int16_t *data, size_t frames)
{
   if (g_cb.audio_batch)
      return g_cb.audio_batch(g_cb.ctx, data, frames);
   return frames; /* claim consumption so cores keep running */
}

static void shim_input_poll(void)
{
   if (g_cb.input_poll)
      g_cb.input_poll(g_cb.ctx);
}

static int16_t shim_input_state(unsigned port, unsigned device, unsigned index, unsigned id)
{
   if (g_cb.input_state)
      return g_cb.input_state(g_cb.ctx, port, device, index, id);
   return 0;
}

static bool shim_environment(unsigned cmd, void *data)
{
   if (g_cb.environment)
      return g_cb.environment(g_cb.ctx, cmd, data);
   return false;
}

void shim_log_printf(enum retro_log_level level, const char *fmt, ...)
{
   if (!g_cb.log)
      return;

   char buf[2048];
   va_list ap;
   va_start(ap, fmt);
   vsnprintf(buf, sizeof(buf), fmt, ap);
   va_end(ap);

   g_cb.log(g_cb.ctx, (int)level, buf);
}

/* --- installation --------------------------------------------------- */

/*
 * Resolve the core's retro_set_* functions at runtime via RTLD_DEFAULT.
 * This keeps shim.c free of link-time dependencies on the core: the core
 * dylib is dlopen'd with RTLD_GLOBAL, which makes its symbols visible to
 * this lookup. Same strategy RetroArch uses.
 */
void shim_install(void)
{
   /* Must run after shim_set_callbacks and BEFORE retro_init. */
   retro_set_environment_t set_env =
      (retro_set_environment_t)dlsym(RTLD_DEFAULT, "retro_set_environment");
   retro_set_video_refresh_t set_video =
      (retro_set_video_refresh_t)dlsym(RTLD_DEFAULT, "retro_set_video_refresh");
   retro_set_audio_sample_t set_audio =
      (retro_set_audio_sample_t)dlsym(RTLD_DEFAULT, "retro_set_audio_sample");
   retro_set_audio_sample_batch_t set_audio_batch =
      (retro_set_audio_sample_batch_t)dlsym(RTLD_DEFAULT, "retro_set_audio_sample_batch");
   retro_set_input_poll_t set_input_poll =
      (retro_set_input_poll_t)dlsym(RTLD_DEFAULT, "retro_set_input_poll");
   retro_set_input_state_t set_input_state =
      (retro_set_input_state_t)dlsym(RTLD_DEFAULT, "retro_set_input_state");

   if (set_env) set_env(shim_environment);
   else fprintf(stderr, "shim: retro_set_environment not found\n");
   if (set_video) set_video(shim_video);
   if (set_audio) set_audio(shim_audio);
   if (set_audio_batch) set_audio_batch(shim_audio_batch);
   if (set_input_poll) set_input_poll(shim_input_poll);
   if (set_input_state) set_input_state(shim_input_state);
}

retro_log_printf_t shim_get_log_printf(void) { return shim_log_printf; }
