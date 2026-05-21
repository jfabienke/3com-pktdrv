/* packet.c — unified TX/RX entry (HOT/resident). The hot path is JIT-emitted; these are
 * the control-plane fallbacks that call through the vtable. */
#include "hardware.h"

int packet_send(nic_info_t *nic, const uint8_t *pkt, uint16_t len)
{
    if (!nic || !nic->ops || !nic->ops->send) return -1;
    return nic->ops->send(nic, pkt, len);
}

int packet_recv(nic_info_t *nic, uint8_t *buf, uint16_t *len)
{
    if (!nic || !nic->ops || !nic->ops->recv) return -1;
    return nic->ops->recv(nic, buf, len);
}
