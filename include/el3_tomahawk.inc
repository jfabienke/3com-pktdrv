; el3_tomahawk.inc -- 3C509 EtherLink III ISA delta (3Com codename "Tomahawk").
;
; The original EtherLink III: ISA bus, PIO datapath -- the 5150 floor NIC. Its delta over
; the shared core is the ISA ID-port contention/activation protocol (no fixed I/O base at
; power-on; the card answers on the shared ID port until activated).
;
; Constants verified against the Nestor 8086 3c509 packet driver.

%ifndef EL3_TOMAHAWK_INC
%define EL3_TOMAHAWK_INC

%include "el3_core.inc"

EL3_PRODID_3C509B       equ 0x9050   ; product id (EEPROM word 3, masked) -- as read
EL3_PRODID_MASK         equ 0xF0FF   ; mask off revision nibble
EL3_IO_EXTENT           equ 16       ; I/O port range per NIC

; ---- ISA ID-port contention / activation protocol ----
EL3_ID_PORT             equ 0x0110   ; shared ID / activation port (default)
EL3_ID_RESET            equ 0x00     ; write twice: select + reset the pattern generator
EL3_ID_GLOBAL_RESET     equ 0xC0     ; global-reset the adapter (between ID-pattern writes)
EL3_ID_TAG_BASE         equ 0xD0     ; 0xD0 clears all tags; OR with tag (1..) to set one
EL3_ID_ACTIVATE_CFG     equ 0xFF     ; activate at the card's EEPROM-configured I/O base
EL3_ID_ACTIVATE_SETIO   equ 0xE0     ; alt: OR with (io_base >> 4) to override the base

%endif ; EL3_TOMAHAWK_INC
