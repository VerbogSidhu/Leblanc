/*
 * shim.h — GameDock's libretro callback trampoline interface.
 *
 * Swift cannot pass capturing closures as C function pointers, and cannot
 * implement C variadic functions. This shim solves both problems:
 *
 *   1. Swift registers non-capturing @convention(c) callbacks + an opaque
 *      context in `shim_callbacks_t` via `shim_set_callbacks`.
 *   2. Static C trampolines (exact libretro signatures) forward core
 *      callbacks to the registered Swift callbacks.
 *   3. `shim_log_printf` is a variadic C function that cores can use via
 *      RETRO_ENVIRONMENT_GET_LOG_INTERFACE; it formats the message with
 *      vsnprintf and forwards a plain C string to the Swift log callback.
 */
#ifndef SHIM_H__
#define SHIM_H__

#include "libretro.h"

#ifdef __cplusplus
extern "C" {
#endif

typedef void *shim_context_t;

typedef struct shim_callbacks
{
   shim_context_t ctx;

   /* video refresh: (ctx, data, width, height, pitch) */
   void (*video)(shim_context_t ctx, const void *data, unsigned width, unsigned height, size_t pitch);

   /* audio sample: (ctx, left, right) */
   void (*audio)(shim_context_t ctx, int16_t left, int16_t right);

   /* audio batch: returns frames consumed */
   size_t (*audio_batch)(shim_context_t ctx, const int16_t *data, size_t frames);

   /* input poll */
   void (*input_poll)(shim_context_t ctx);

   /* input state: returns analog value or button state */
   int16_t (*input_state)(shim_context_t ctx, unsigned port, unsigned device, unsigned index, unsigned id);

   /* environment: returns true if handled */
   bool (*environment)(shim_context_t ctx, unsigned cmd, void *data);

   /* formatted log message: (ctx, level, message) */
   void (*log)(shim_context_t ctx, int level, const char *message);

} shim_callbacks_t;

/* Register Swift callbacks (must be done before retro_init). */
void shim_set_callbacks(shim_callbacks_t cb);

/* Install the trampolines into the loaded core (retro_set_*). */
void shim_install(void);

/* Variadic log printf handed to cores via GET_LOG_INTERFACE. */
void shim_log_printf(enum retro_log_level level, const char *fmt, ...);

#ifdef __cplusplus
}
#endif

#endif /* SHIM_H__ */

/* Return the raw variadic log printf. Swift imports retro_log_printf_t as an
 * opaque pointer (it cannot name variadic C function pointer types), so cores'
 * RETRO_ENVIRONMENT_GET_LOG_INTERFACE struct is filled from here. */
retro_log_printf_t shim_get_log_printf(void);
