; api.asm -- Crynwr Packet Driver INT 60h dispatch entry (8086 floor stub).
;
; Placeholder for the emitted INT 60h handler. The real AH-function dispatch
; (driver_info / access_type / release_type / send_pkt / get_address / set_rcv_mode) and
; the handle table land in the next milestone; for now it is a bare return so the composed
; image links and is locatable via compose_result_t.off[FRAG_API_DISPATCH].
bits 16
cpu 8086

        ret
