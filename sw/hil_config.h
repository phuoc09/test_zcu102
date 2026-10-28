#ifndef HIL_CONFIG_H
#define HIL_CONFIG_H

/* Ranking-key configuration of the bitstream this application talks to.
 * Override with -DHIL_K=0 for the original-ALM bitstream; default K=4. */
#ifndef HIL_K
#define HIL_K 4
#endif

#endif
