#ifndef AUDIOTAP_CLEVELCELL_H
#define AUDIOTAP_CLEVELCELL_H

#include <stdint.h>

// `nonblocking` makes clang reject a lock, an allocation or any other blocking
// call inside the two functions the real-time IO thread calls (an error under
// the target's `-Werror=function-effects`), the same attribute Core Audio puts
// on its IO block type (`CA_REALTIME_API`).
#if defined(__has_attribute) && __has_attribute(nonblocking)
#    define AUDIOTAP_NONBLOCKING __attribute__((nonblocking))
#else
#    define AUDIOTAP_NONBLOCKING
#endif

#pragma clang assume_nonnull begin

/// The newest level of one meter and the mach tick it was taken at, shared
/// between the device's real-time IO thread (the only writer) and any reader
/// without a lock. The writer stores both halves with relaxed C11 atomics, so a
/// reader can see the level of one buffer with the tick of the next; both are
/// fresh, which is all a level bar needs. Opaque, because Swift cannot import
/// `_Atomic` fields.
typedef struct audiotap_level_cell audiotap_level_cell;

/// A cell that reads level -120 dBFS at tick 0, the "never delivered" reading.
/// Aborts when the allocation fails, as a Swift allocation would.
audiotap_level_cell *audiotap_level_cell_create(void);

/// Frees the cell. Only once no callback can store into it any more.
void audiotap_level_cell_destroy(audiotap_level_cell *cell);

/// Called from the IO thread once per buffer.
void audiotap_level_cell_store(audiotap_level_cell *cell, double level, uint64_t ticks) AUDIOTAP_NONBLOCKING;

/// The stored level, and its tick through `ticks`.
double audiotap_level_cell_load(const audiotap_level_cell *cell, uint64_t *ticks) AUDIOTAP_NONBLOCKING;

#pragma clang assume_nonnull end

#endif
