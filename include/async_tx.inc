; async_tx.inc -- proprietary asynchronous zero-copy TX extension to the Crynwr packet-driver ABI.
;
; PURELY ADDITIVE: standard send_pkt (AH=4, synchronous copy) is unchanged, so legacy Crynwr stacks
; (mTCP, WATTCP, NCSA, ...) are unaffected. This vendor function sits above the standard range (1-28),
; next to the XMS DMA extension (AH=0xF0). An async-aware stack probes ASYNC_INFO and falls back to
; send_pkt if CF=1 (unsupported: 286 blocking path, PIO mode, or a build without async).
;
; CONTRACT (differs from send_pkt!): ASYNC_SEND does NOT copy the frame. The caller's buffer must stay
; valid and unmodified until that frame's DMA completes -- detected by watching tx_completed advance.
; The caller uses a buffer POOL (>= TX_RING_N) and throttles: post frame S into buf[S mod N] only once
; (posted - tx_completed) < TX_RING_N, which guarantees buf[S mod N]'s previous user (post S-N) is done.

ASYNC_TX_FUNC   equ 0xF1    ; INT 60h AH value (vendor; above Crynwr 1-28, beside XMS DMA 0xF0)

; AL sub-functions (in AL on entry, like the XMS extension):
ASYNC_INFO      equ 0       ; -> CF=0; AX=TX_RING_N, DX:CX=&tx_completed (u16), BX=feature flags
ASYNC_SEND      equ 1       ; DS:SI=frame, CX=len -> post zero-copy non-blocking; CF=0 queued / CF=1 full

; ASYNC_INFO feature flags (BX):
ASYNC_FEAT_ZEROCOPY equ 0x0001   ; descriptors point at the caller's buffer (no slot copy)
