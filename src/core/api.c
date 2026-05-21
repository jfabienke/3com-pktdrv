/* api.c — Crynwr INT 60h dispatch (HOT/resident). Stub for the milestone. */
#include "pktdrv.h"
#include "hardware.h"

/* The real per-call hot dispatch is JIT-emitted (FRAG_API_DISPATCH). This C entry is the
 * cold-installed trampoline target / fallback. */
int api_driver_info(uint16_t *version)
{
    if (version) *version = PKT_API_VERSION;
    return 0;
}
