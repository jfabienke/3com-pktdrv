/* el3_isa.c — ISA EtherLink III families. 3C509B is the PIO floor; 3C515 adds the
 * ISA bus-master ring (later). Vtables reuse el3_core for shared behavior (docs/03). */
#include "hardware.h"
#include "codegen.h"

/* shared core (el3_core.c) */
extern int el3_init(nic_info_t *);
extern int el3_reset(nic_info_t *);
extern int el3_send_pio(nic_info_t *, const uint8_t *, uint16_t);
extern int el3_recv_pio(nic_info_t *, uint8_t *, uint16_t *);
extern int el3_set_rx_mode(nic_info_t *, uint8_t);
extern int el3_get_mac(nic_info_t *, uint8_t[6]);

/* Cold: name the hot fragments the composer must emit for a 3C509B (PIO floor), and hand
 * each its immediates. The PIO datapath fragments take io_base in patch slot 0. */
static void c509b_emit_plan(nic_info_t *nic, emit_plan_t *plan)
{
    uint8_t s = 0;
    plan->steps[s] = FRAG_API_DISPATCH;                       s++;
    plan->steps[s] = FRAG_ISR_ENTRY;                          s++;
    plan->steps[s] = FRAG_RX_PIO; plan->imm[s][0] = nic->io_base; s++;
    plan->steps[s] = FRAG_TX_PIO; plan->imm[s][0] = nic->io_base; s++;
    plan->steps[s] = FRAG_ISR_EOI;                            s++;
    plan->n_steps = s;
}

const nic_ops_t el3_3c509b_ops = {
    el3_init,
    el3_reset,
    el3_send_pio,
    el3_recv_pio,
    0,                  /* isr: JIT-emitted */
    el3_set_rx_mode,
    el3_get_mac,
    c509b_emit_plan
};
