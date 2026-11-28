#pragma once
#include <stdint.h>

// Metal pixel formats, also used by the Foundation-only serialized-key tests.
enum { PSO_D16 = 250, PSO_D32 = 252, PSO_S8 = 253, PSO_D32S8 = 260, PSO_X32S8 = 261 };

// iOS rejects a combined stencil format with no matching depth format (#702).
// The pass attaches both planes of combined storage, even when lookahead uses
// only one. Match that in live, predicted and historical prewarm keys. Never
// replace a nonzero, conflicting format or invent storage for an empty pass.
static inline void pso_ds_pair(uint32_t *depth, uint32_t *stencil) {
    if (!*depth && *stencil == PSO_D32S8) *depth = PSO_D32S8;
    if (!*stencil && *depth == PSO_D32S8) *stencil = PSO_D32S8;
}

static inline int pso_ds_valid(uint32_t depth, uint32_t stencil) {
    if (depth && depth != PSO_D16 && depth != PSO_D32 && depth != PSO_D32S8) return 0;
    if (stencil && stencil != PSO_S8 && stencil != PSO_D32S8 && stencil != PSO_X32S8) return 0;
    if (depth == PSO_D32S8 || stencil == PSO_D32S8) return depth == stencil;
    return 1;
}

// Color-renderable Metal pixel formats on Apple GPUs (0 = MTLPixelFormatInvalid / unused slot).
// Matches mtl_pf_bytes() in nvn_mtl.m: rejects depth/stencil, compressed, and unknown formats
// before either MTLDevice or MTL4Compiler can assert or accept an unrenderable pipeline (#3462).
static inline int pso_color_valid(uint32_t format) {
    switch (format) {
        case 0:
        case 10: case 11: case 12: case 13: case 14:
        case 20: case 22: case 23: case 24: case 25:
        case 30: case 31: case 32: case 33: case 34:
        case 40: case 41: case 42: case 43:
        case 53: case 54: case 55:
        case 60: case 62: case 63: case 64: case 65:
        case 70: case 71: case 72: case 73: case 74:
        case 80: case 81:
        case 90: case 91: case 92: case 93: case 94:
        case 103: case 104: case 105:
        case 110: case 112: case 113: case 114: case 115:
        case 123: case 124: case 125:
            return 1;
        default:
            return 0;
    }
}

static inline int pso_formats_valid(const uint32_t cfmt[8], uint32_t depth, uint32_t stencil) {
    if (!pso_ds_valid(depth, stencil)) return 0;
    for (int i = 0; i < 8; i++) if (!pso_color_valid(cfmt[i])) return 0;
    return 1;
}
