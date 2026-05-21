/*
 * el3_regs.h — EtherLink III register / window / EEPROM definitions.
 *
 * The EtherLink III family shares one windowed register model (the lineage's common
 * core): a command/status register always at offset 0x0E, eight selectable register
 * windows, and a common command/status bit layout. 3C509B is the PIO floor; 3C515 and
 * the PCI generations add a bus-master register set (Window 7 list pointers).
 *
 * Lifted (facts only) from the prior repo's 3c509b.h / 3c515.h.  EL3_* = shared core;
 * family-specific additions are noted.  See docs/03-hal-vtable.md, docs/07-porting-plan.md.
 */
#ifndef PKTDRV_EL3_REGS_H
#define PKTDRV_EL3_REGS_H

/* ---- identity ---- */
#define EL3_MFG_ID              0x6D50   /* 3Com manufacturer ID (EEPROM)      */
#define EL3_PRODID_3C509B       0x5090   /* 3C509B product ID                  */
#define EL3_PRODID_MASK         0xF0FF   /* mask off revision nibble           */
#define EL3_ID_PORT             0x110    /* ISA ID/activation port (3C509B)    */
#define EL3_IO_EXTENT           16       /* I/O port range per NIC             */

/* ---- frame sizing ---- */
#define EL3_MAX_FRAME           1514     /* MTU + header, no CRC               */
#define EL3_MIN_FRAME           60       /* min frame, no CRC                  */

/* ---- command / status register (ALWAYS accessible, all windows) ---- */
#define EL3_CMD                 0x0E     /* write: command                     */
#define EL3_STATUS              0x0E     /* read:  status (same offset)        */

/* ---- register windows ---- */
#define EL3_W0_SETUP            0        /* config + EEPROM                    */
#define EL3_W1_OPERATING        1        /* TX/RX FIFO + status                */
#define EL3_W2_STATION_ADDR     2        /* station (MAC) address              */
#define EL3_W3_CONFIG           3        /* internal config                    */
#define EL3_W4_MEDIA            4        /* media / diagnostics / MII          */
#define EL3_W6_STATS            6        /* statistics counters                */
#define EL3_W7_BUSMASTER        7        /* bus-master list pointers (3C515+)  */

/* ---- commands (written to EL3_CMD; high 5 bits select the command) ---- */
#define EL3_CMD_GLOBAL_RESET    0x0000
#define EL3_CMD_SELECT_WINDOW   0x0800   /* OR with window #                   */
#define EL3_CMD_START_COAX      0x1000
#define EL3_CMD_RX_DISABLE      0x1800
#define EL3_CMD_RX_ENABLE       0x2000
#define EL3_CMD_RX_RESET        0x2800
#define EL3_CMD_RX_DISCARD      0x4000   /* discard top RX packet              */
#define EL3_CMD_TX_ENABLE       0x4800
#define EL3_CMD_TX_DISABLE      0x5000
#define EL3_CMD_TX_RESET        0x5800
#define EL3_CMD_REQUEST_INTR    0x6000
#define EL3_CMD_ACK_INTR        0x6800   /* OR with status bits to ack         */
#define EL3_CMD_SET_INTR_ENB    0x7000   /* OR with mask                       */
#define EL3_CMD_SET_STATUS_ENB  0x7800   /* OR with mask                       */
#define EL3_CMD_SET_RX_FILTER   0x8000   /* OR with filter bits                */
#define EL3_CMD_SET_RX_EARLY    0x8800
#define EL3_CMD_SET_TX_AVAIL    0x9000
#define EL3_CMD_SET_TX_START    0x9800
#define EL3_CMD_STATS_ENABLE    0xA800
#define EL3_CMD_STATS_DISABLE   0xB000
#define EL3_CMD_STOP_COAX       0xB800
#define EL3_CMD_MASK            0xF800
#define EL3_CMD_PARAM_MASK      0x07FF
#define EL3_MAKE_CMD(c,p)       ((c) | ((p) & EL3_CMD_PARAM_MASK))

/* ---- status bits (read from EL3_STATUS) ---- */
#define EL3_ST_INT_LATCH        0x0001
#define EL3_ST_ADAPTER_FAIL     0x0002
#define EL3_ST_TX_COMPLETE      0x0004
#define EL3_ST_TX_AVAILABLE     0x0008
#define EL3_ST_RX_COMPLETE      0x0010
#define EL3_ST_RX_EARLY         0x0020
#define EL3_ST_INT_REQ          0x0040
#define EL3_ST_STATS_FULL       0x0080
#define EL3_ST_CMD_BUSY         0x1000

/* ---- Window 0: config + EEPROM ---- */
#define EL3_W0_CONFIG_CTRL      0x04
#define EL3_W0_ADDR_CONFIG      0x06
#define EL3_W0_IRQ              0x08
#define EL3_W0_EEPROM_CMD       0x0A
#define EL3_W0_EEPROM_DATA      0x0C
#define EL3_EEPROM_READ         0x80     /* OR with word address               */
#define EL3_EEPROM_READ_DELAY_US 2000

/* EEPROM word offsets */
#define EL3_EE_ADDR_LO          0x00     /* station addr words 0..2            */
#define EL3_EE_ADDR_MID         0x01
#define EL3_EE_ADDR_HI          0x02
#define EL3_EE_PRODUCT_ID       0x03

/* ---- Window 1: operating (TX/RX FIFO + status) ---- */
#define EL3_W1_TX_FIFO          0x00     /* write packet data                  */
#define EL3_W1_RX_FIFO          0x00     /* read packet data                   */
#define EL3_W1_RX_STATUS        0x08
#define EL3_W1_TX_STATUS        0x0B
#define EL3_W1_TX_FREE          0x0C     /* free bytes in TX FIFO              */

/* RX status (W1_RX_STATUS) */
#define EL3_RX_INCOMPLETE       0x8000
#define EL3_RX_ERROR            0x4000
#define EL3_RX_LEN_MASK         0x07FF

/* TX status (W1_TX_STATUS) */
#define EL3_TX_COMPLETE         0x80
#define EL3_TX_INTR             0x40

/* RX filter bits (EL3_CMD_SET_RX_FILTER) */
#define EL3_RXF_STATION         0x01
#define EL3_RXF_MULTICAST       0x02
#define EL3_RXF_BROADCAST       0x04
#define EL3_RXF_PROMISCUOUS     0x08

/* ---- Window 7: bus-master (3C515 ISA + PCI generations) ---- */
/* These offsets are >0xFF (extended I/O); used only when HW_CAP_RING_DMA. */
#define EL3_W7_DMA_CTRL         0x400
#define EL3_W7_DOWN_LIST_PTR    0x404    /* TX descriptor list (physical)      */
#define EL3_W7_DOWN_POLL        0x408
#define EL3_W7_UP_PKT_STATUS    0x410
#define EL3_W7_UP_LIST_PTR      0x418    /* RX descriptor list (physical)      */
#define EL3_W7_UP_POLL          0x41C

#endif /* PKTDRV_EL3_REGS_H */
