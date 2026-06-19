; cache.asm -- bus-master DMA cache-coherency flush helper (Phase 2; %included RESIDENT by start.asm).
;
; The DMA datapaths `call word [g_cache_flush_fn]` at the coherency-critical points:
;   TX  -- before the card reads the frame + descriptor (tx_kick / dma_tx_single): write back any dirty
;          CPU writes so the bus master reads fresh bytes (a write-back cache hazard; harmless on write-through).
;   RX  -- at the TOP of the conv-ring drain (f_xms_poll), ONCE per drain (batched -- a per-frame WBINVD
;          ~250 us would exceed the ~121 us inter-frame budget): invalidate so the CPU reads the card's
;          fresh descriptor STATUS (UP_COMPLETE) + slot payload, not a stale cached copy.
;
; The cold coherency self-test (docs/13, docs/17 -- step 2, not yet landed) selects the body by pointing
; g_cache_flush_fn at one of the routines below. Until then it stays cache_flush_none (the coherent verdict),
; which is also what a snooping cache / no cache / the QEMU emulator (no cache modelled) resolve to.
;
; CONTRACT: every routine here preserves ALL general registers AND the flags -- the DMA-path call sites do
; NOT save anything around the call. (cache_flush_evict, a later 386 tier, must push/pop its scratch.)
; WBINVD is the safe universal flush (writes back THEN invalidates); never INVD (0F08) -- it discards dirty
; lines (data loss) and is only safe on a proven-write-through hierarchy. See docs/13.

; Flush-tier ids -- the cold RX coherency self-test (phase_validate_coherency) records its verdict in
; g_flush_tier; install maps the id to the resident helper below. (Kept as small ints, not helper
; offsets, so the cold pass needn't know the resident layout.)
FLUSH_TIER_NONE         equ 0                   ; coherent -> cache_flush_none
FLUSH_TIER_WBINVD       equ 1                   ; non-coherent, 486+ -> cache_flush_wbinvd
FLUSH_TIER_EVICT        equ 2                   ; non-coherent 386 software sweep -- DEFERRED (docs/17 step 4)

cache_flush_none:
        ret                                     ; coherent: snoop / no cache / NC-effective / emulator

cache_flush_wbinvd:                             ; non-coherent, 486+ (selected only on 486+; never called on 386)
        db      0x0F, 0x09                      ; WBINVD -- no GP-reg / flag effect, so the contract holds
        ret
