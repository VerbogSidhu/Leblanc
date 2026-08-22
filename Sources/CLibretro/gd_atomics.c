#include "gd_atomics.h"

int64_t gd_atomic_load_i64(const int64_t *p) {
    return __atomic_load_n(p, __ATOMIC_ACQUIRE);
}

void gd_atomic_store_i64(int64_t *p, int64_t v) {
    __atomic_store_n(p, v, __ATOMIC_RELEASE);
}
