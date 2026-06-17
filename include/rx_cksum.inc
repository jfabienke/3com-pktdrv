; rx_cksum.inc -- proprietary RX software-checksum-offload extension to the Crynwr packet-driver ABI.
;
; PURELY ADDITIVE (sits beside XMS DMA AH=0xF0 and async TX AH=0xF1; standard send/receive unchanged,
; so mTCP/WATTCP are unaffected). When enabled, the driver accumulates the 16-bit ones-complement sum
; of each received frame's IP+TCP+payload bytes DURING its mandatory PIO FIFO drain -- on real ISA
; hardware the fold hides behind the ~1 us `in` (nearly free), letting an offload-aware stack skip the
; whole-segment software checksum pass. The folded sum is handed to the receiver in DX at the AX=1
; deliver upcall (legacy receivers ignore DX). The stack subtracts the IP-header sum and adds the
; pseudo-header (~16 words) to get the TCP verdict.
;
; The sum covers exactly the bytes the ISR drains: the frame minus the 14-byte Ethernet header, i.e.
; the IP packet plus any Ethernet padding. The stack must only trust it when there is NO padding
; (drained length == IP total length); for full-MSS data frames there is none.
;
; NOTE on measurement: under QEMU -icount (one time-per-instruction, no per-access ISA-bus latency,
; see el3_core.h), the fold's `adc`s are charged at full CPU rate instead of hiding behind the slow
; `in`, so this offload does NOT improve the modeled throughput -- it is a real-hardware lever. It is
; built + correctness-validated here; the measurable RX win in the emulator is copy reduction.

RX_CKSUM_FUNC    equ 0xF2    ; INT 60h AH value (vendor; beside XMS DMA 0xF0 / async TX 0xF1)
RX_CKSUM_QUERY   equ 0x00    ; AL -> CF=0 supported; AX=1, BX=feature flags
RX_CKSUM_ENABLE  equ 0x01    ; AL -> turn offload on  (CF=0)
RX_CKSUM_DISABLE equ 0x02    ; AL -> turn offload off (CF=0)

RXCK_FEAT_IPSUM  equ 0x0001  ; DX at deliver = folded native-LE sum over (IP + TCP + payload)
