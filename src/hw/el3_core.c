/* el3_core.c — shared EtherLink III behavior reused by family vtables (docs/03).
 * PIO floor: window select, reset, EEPROM-less stubs, PIO send/recv skeleton.
 * COLD for init/control; the per-packet hot path is JIT-emitted, not these. */
#include "hardware.h"
#include "el3_regs.h"
#include <conio.h>          /* Open Watcom: inp/outp/inpw/outpw */

void el3_select_window(uint16_t io, uint8_t win)
{
    outpw(io + EL3_CMD, (uint16_t)(EL3_CMD_SELECT_WINDOW | win));
}

int el3_reset(nic_info_t *nic)
{
    outpw(nic->io_base + EL3_CMD, EL3_CMD_GLOBAL_RESET);
    return 0;
}

int el3_init(nic_info_t *nic)
{
    el3_reset(nic);
    el3_select_window(nic->io_base, EL3_W1_OPERATING);
    return 0;
}

int el3_set_rx_mode(nic_info_t *nic, uint8_t mode)
{
    outpw(nic->io_base + EL3_CMD, (uint16_t)(EL3_CMD_SET_RX_FILTER | mode));
    return 0;
}

int el3_get_mac(nic_info_t *nic, uint8_t mac[6])
{
    int i;
    for (i = 0; i < 6; ++i) mac[i] = nic->mac[i];
    return 0;
}

/* PIO transmit (floor): preamble = length word, then the frame to the TX FIFO. */
int el3_send_pio(nic_info_t *nic, const uint8_t *pkt, uint16_t len)
{
    uint16_t io = nic->io_base;
    uint16_t i;
    outpw(io + EL3_W1_TX_FIFO, len);
    outpw(io + EL3_W1_TX_FIFO, 0);
    for (i = 0; i + 1 < len; i += 2)
        outpw(io + EL3_W1_TX_FIFO, *(const uint16_t *)(pkt + i));
    if (i < len)
        outp(io + EL3_W1_TX_FIFO, pkt[i]);
    return 0;
}

/* PIO receive (floor): read RX status for length, drain the FIFO. */
int el3_recv_pio(nic_info_t *nic, uint8_t *buf, uint16_t *len)
{
    uint16_t io = nic->io_base;
    uint16_t st = inpw(io + EL3_W1_RX_STATUS);
    uint16_t n, i;

    if (st & EL3_RX_INCOMPLETE) return -1;
    n = st & EL3_RX_LEN_MASK;
    if (n > *len) n = *len;
    for (i = 0; i + 1 < n; i += 2)
        *(uint16_t *)(buf + i) = inpw(io + EL3_W1_RX_FIFO);
    if (i < n)
        buf[i] = (uint8_t)inp(io + EL3_W1_RX_FIFO);
    outpw(io + EL3_CMD, EL3_CMD_RX_DISCARD);   /* pop the packet */
    *len = n;
    return 0;
}
