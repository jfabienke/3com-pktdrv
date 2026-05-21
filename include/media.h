/*
 * media.h — media type / transceiver enums.
 * TIER-A LIFT TARGET: port the factual enums from old include/media_types.h
 * (10baseT, 10base2, AUI, 100baseTX, MII, auto), used by media selection.
 */
#ifndef PKTDRV_MEDIA_H
#define PKTDRV_MEDIA_H

typedef enum {
    MEDIA_AUTO = 0,
    MEDIA_10BASE_T,
    MEDIA_10BASE_2,
    MEDIA_AUI,
    MEDIA_100BASE_TX,
    MEDIA_MII
} media_type_t;

#endif /* PKTDRV_MEDIA_H */
