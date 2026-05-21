/*
 * pktdrv.h — Crynwr Packet Driver API constants (lift function numbers from old api.h).
 * Semantics: INT 60h, AH=function, BX=handle, DS:SI/ES:DI=params, AX=result,
 * CF set on error / clear on success; "PKT DRVR" signature at vector+3.
 * See docs/01-constraints.md.
 */
#ifndef PKTDRV_API_H
#define PKTDRV_API_H

#include <stdint.h>

#define PKT_INT_DEFAULT     0x60
#define PKT_SIGNATURE       "PKT DRVR"   /* placed at handler vector+3 */
#define PKT_API_VERSION     0x0111       /* v1.11 */

/* Standard functions (AH). */
#define PD_DRIVER_INFO      0x01
#define PD_ACCESS_TYPE      0x02
#define PD_RELEASE_TYPE     0x03
#define PD_SEND_PKT         0x04
#define PD_TERMINATE        0x05
#define PD_GET_ADDRESS      0x06
#define PD_RESET_INTERFACE  0x07
#define PD_GET_PARAMETERS   0x0A
#define PD_SET_RCV_MODE     0x14
#define PD_GET_RCV_MODE     0x15
#define PD_SET_MULTICAST    0x16
#define PD_GET_STATISTICS   0x18

/* Error codes returned in DH (CF set). */
#define PDE_BAD_HANDLE      1
#define PDE_NO_CLASS        2
#define PDE_NO_TYPE         3
#define PDE_NO_NUMBER       4
#define PDE_BAD_TYPE        5
#define PDE_NO_MULTICAST    6
#define PDE_CANT_TERMINATE  7
#define PDE_BAD_MODE        8
#define PDE_NO_SPACE        9
#define PDE_TYPE_INUSE      10
#define PDE_BAD_COMMAND     11
#define PDE_CANT_SEND       12

#endif /* PKTDRV_API_H */
