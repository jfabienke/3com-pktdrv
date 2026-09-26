/* shims for isapnptools on Open Watcom real-mode DOS */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <conio.h>
#include "getopt.h"

/* ~1 us per ISA I/O read of the POST/DMA-page port, independent of CPU speed */
unsigned usleep(unsigned us)
{
    unsigned long n = (unsigned long)us + 1;
    while (n--) (void)inp(0x80);
    return 0;
}

char *optarg = NULL; int optind = 1, opterr = 1, optopt = 0;
static int nextc = 0;

int getopt_long(int argc, char *const argv[], const char *shortopts,
                const struct option *longopts, int *longind)
{
    char *a; const char *p;
    optarg = NULL;
    if (optind >= argc) return EOF;
    a = argv[optind];
    if (nextc == 0) {
        if (a[0] != '-' || a[1] == 0) return EOF;
        if (a[1] == '-' && a[2] == 0) { optind++; return EOF; }
        if (a[1] == '-') {                       /* --long[=arg] */
            const char *name = a + 2, *eq = strchr(name, '=');
            size_t nl = eq ? (size_t)(eq - name) : strlen(name);
            int i;
            optind++;
            for (i = 0; longopts && longopts[i].name; i++) {
                if (strlen(longopts[i].name) == nl && strncmp(longopts[i].name, name, nl) == 0) {
                    if (longind) *longind = i;
                    if (longopts[i].has_arg) {
                        if (eq) optarg = (char *)eq + 1;
                        else if (longopts[i].has_arg == 1 && optind < argc) optarg = argv[optind++];
                    }
                    if (longopts[i].flag) { *longopts[i].flag = longopts[i].val; return 0; }
                    return longopts[i].val;
                }
            }
            return '?';
        }
        nextc = 1;
    }
    optopt = a[nextc];
    p = strchr(shortopts, optopt);
    nextc++;
    if (!p || optopt == ':') { if (!a[nextc]) { nextc = 0; optind++; } return '?'; }
    if (p[1] == ':') {
        if (a[nextc]) optarg = a + nextc;
        else if (p[2] != ':' && optind + 1 < argc) optarg = argv[++optind];
        nextc = 0; optind++;
    } else if (!a[nextc]) { nextc = 0; optind++; }
    return optopt;
}
