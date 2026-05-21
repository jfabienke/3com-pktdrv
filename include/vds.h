/*
 * vds.h — Virtual DMA Services (INT 4Bh) primitives.
 * TIER-A LIFT TARGET: port the old repo's src/c/vds.c + include/vds.h (~clean, ~193 lines):
 * VDS presence test, lock/unlock region, request/release common buffer, contiguity check.
 * Used by the COMMONBUF dma_policy under a VMM (docs/04-dma-model.md).
 */
#ifndef PKTDRV_VDS_H
#define PKTDRV_VDS_H
#include <stdint.h>
#include <stdbool.h>

#define VDS_SUCCESS 0x00

/* VDS DMA descriptor (DDS). */
typedef struct {
    uint32_t size;
    uint32_t offset;
    uint16_t segment;
    uint16_t buffer_id;
    uint32_t physical;
    uint16_t flags;
} vds_dds_t;

bool    vds_available(void);
uint8_t vds_lock_region(void far *ptr, uint32_t size, vds_dds_t *dds);
uint8_t vds_unlock_region(vds_dds_t *dds);
uint8_t vds_request_buffer(uint32_t size, vds_dds_t *dds);
uint8_t vds_release_buffer(vds_dds_t *dds);

#endif /* PKTDRV_VDS_H */
