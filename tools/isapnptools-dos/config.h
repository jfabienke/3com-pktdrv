/* Open Watcom real-mode DOS config for isapnptools (mirrors include/config.bor) */
#ifndef ISAPNP_OW_CONFIG_H
#define ISAPNP_OW_CONFIG_H
#define __TURBOC__ 1                  /* iopl.h: plain DOS (dos.h), no ioperm */
#define __DJGPP__ 1                   /* pnp.h: outportb/inportb port macros */
#include <conio.h>
#include <dos.h>
#include <i86.h>
#define outportb(p, v) outp((p), (v))
#define inportb(p)     inp(p)
#define __attribute__(x)
#define inline
#define HAVE_USLEEP 1
unsigned usleep(unsigned us);
#include <stdio.h>
#include <stddef.h>
#define HAVE_SNPRINTF 1
#define YY_NO_UNISTD_H 1              /* flex scanner: Watcom's unistd.h clashes with the GNU getopt globals */
#include <io.h>                        /* isatty/fileno for the flex scanner */
#define PACKAGE "isapnptools"
#define VERSION "1.27 (Open Watcom real-mode DOS)"
#endif
