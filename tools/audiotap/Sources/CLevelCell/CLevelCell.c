#include "CLevelCell.h"

#include <stdatomic.h>
#include <stdlib.h>

struct audiotap_level_cell {
    _Atomic uint64_t level_bits;
    _Atomic uint64_t ticks;
};

_Static_assert(sizeof(double) == sizeof(uint64_t), "a level is stored as its 64 bits");

// A union rather than memcpy: C defines punning through a union, and it keeps
// a library call out of the functions marked nonblocking.
typedef union {
    double level;
    uint64_t bits;
} level_pun;

static uint64_t bits_of(double level) AUDIOTAP_NONBLOCKING {
    level_pun pun = {.level = level};
    return pun.bits;
}

static double level_of(uint64_t bits) AUDIOTAP_NONBLOCKING {
    level_pun pun = {.bits = bits};
    return pun.level;
}

audiotap_level_cell *audiotap_level_cell_create(void) {
    audiotap_level_cell *cell = malloc(sizeof *cell);
    if (cell == NULL) {
        abort();
    }
    atomic_init(&cell->level_bits, bits_of(-120.0));
    atomic_init(&cell->ticks, 0);
    return cell;
}

void audiotap_level_cell_destroy(audiotap_level_cell *cell) {
    free(cell);
}

void audiotap_level_cell_store(audiotap_level_cell *cell, double level, uint64_t ticks) AUDIOTAP_NONBLOCKING {
    atomic_store_explicit(&cell->level_bits, bits_of(level), memory_order_relaxed);
    atomic_store_explicit(&cell->ticks, ticks, memory_order_relaxed);
}

double audiotap_level_cell_load(const audiotap_level_cell *cell, uint64_t *ticks) AUDIOTAP_NONBLOCKING {
    *ticks = atomic_load_explicit(&cell->ticks, memory_order_relaxed);
    return level_of(atomic_load_explicit(&cell->level_bits, memory_order_relaxed));
}
