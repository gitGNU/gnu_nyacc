// ex1.c
#ifdef __cplusplus__
extern "C" {
#endif
#include "inc.h"

eval_t x;

struct foo;

typedef struct {
  /* hello */
  eval_t x; /* comment */
  int x;
  /* world */
} xyz_t;

int ex1_foo(ex1_t *mod, double t, double *x, int *y) {
   int i = mod->xyz.i;
   ++i;
   return i+2;
}

int x; // this is x 
/* this is lone comment */

#ifdef __cplusplus__
}
#endif
/* --- last line --- */