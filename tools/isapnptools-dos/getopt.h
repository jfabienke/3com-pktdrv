#ifndef OW_GETOPT_H
#define OW_GETOPT_H
struct option { const char *name; int has_arg; int *flag; int val; };
#define no_argument 0
#define required_argument 1
#define optional_argument 2
extern char *optarg; extern int optind, opterr, optopt;
int getopt_long(int argc, char *const argv[], const char *shortopts, const struct option *longopts, int *longind);
#endif
