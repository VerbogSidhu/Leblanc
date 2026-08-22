#ifndef GD_ATOMICS_H
#define GD_ATOMICS_H

/*
 * Minimal acquire/release atomics for the audio handoff ring.
 *
 * The libretro core thread produces samples and AVAudioEngine's realtime
 * render thread consumes them. The consumer runs on a priority-boosted
 * audio-server thread where taking an NSLock can block behind lower-
 * priority work and underrun the SHARED output device — audible glitches
 * in every app on the machine. These helpers let Swift build a lock-free
 * SPSC ring: no locks are ever taken on the render thread.
 *
 * Header-only (static inline) so the C shim target needs no new .c files;
 * clang's importer exposes them to Swift as free functions.
 */

#include <stdint.h>

int64_t gd_atomic_load_i64(const int64_t *p);
void gd_atomic_store_i64(int64_t *p, int64_t v);

#endif /* GD_ATOMICS_H */
