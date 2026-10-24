#include "ctesseract.h"

Pix * _Nullable st_pix_create_from_binary_words(
    int width,
    int height,
    int dpi,
    const uint64_t * _Nonnull words,
    int words_per_row
) {
    if (width <= 0 || height <= 0 || words_per_row <= 0) {
        return NULL;
    }

    Pix *pix = pixCreate(width, height, 1);
    if (!pix) {
        return NULL;
    }

    if (dpi > 0) {
        pixSetResolution(pix, dpi, dpi);
    }

    unsigned int *data = pixGetData(pix);
    int wpl = pixGetWpl(pix);
    if (!data || wpl <= 0) {
        pixDestroy(&pix);
        return NULL;
    }

    for (int y = 0; y < height; ++y) {
        const uint64_t *src_row = words + (size_t)y * (size_t)words_per_row;
        unsigned int *dst_row = data + (size_t)y * (size_t)wpl;

        for (int col64 = 0; col64 < words_per_row; ++col64) {
            uint64_t w64 = src_row[col64];
            int col32_hi = col64 * 2;
            int col32_lo = col32_hi + 1;

            if (col32_hi < wpl) {
                dst_row[col32_hi] = (unsigned int)(w64 >> 32);
            }
            if (col32_lo < wpl) {
                dst_row[col32_lo] = (unsigned int)(w64 & 0xFFFFFFFFULL);
            }
        }
    }

    return pix;
}

Pix * _Nullable st_pix_create_from_grayscale_bytes(
    int width,
    int height,
    int dpi,
    const uint8_t * _Nonnull pixels,
    int row_bytes
) {
    if (width <= 0 || height <= 0 || row_bytes < width) {
        return NULL;
    }

    Pix *pix = pixCreate(width, height, 8);
    if (!pix) {
        return NULL;
    }

    if (dpi > 0) {
        pixSetResolution(pix, dpi, dpi);
    }

    unsigned int *data = pixGetData(pix);
    int wpl = pixGetWpl(pix);
    if (!data || wpl <= 0) {
        pixDestroy(&pix);
        return NULL;
    }

    int full_quads = width / 4;
    int remainder = width & 3;

    for (int y = 0; y < height; ++y) {
        const uint8_t *src_row = pixels + (size_t)y * (size_t)row_bytes;
        unsigned int *dst_row = data + (size_t)y * (size_t)wpl;

        for (int q = 0; q < full_quads; ++q) {
            int x = q * 4;
            unsigned int p0 = (unsigned int)src_row[x];
            unsigned int p1 = (unsigned int)src_row[x + 1];
            unsigned int p2 = (unsigned int)src_row[x + 2];
            unsigned int p3 = (unsigned int)src_row[x + 3];
            dst_row[q] = (p0 << 24) | (p1 << 16) | (p2 << 8) | p3;
        }

        if (remainder > 0 && full_quads < wpl) {
            int x = full_quads * 4;
            unsigned int p0 = (unsigned int)src_row[x];
            unsigned int p1 = (remainder > 1) ? (unsigned int)src_row[x + 1] : 255U;
            unsigned int p2 = (remainder > 2) ? (unsigned int)src_row[x + 2] : 255U;
            unsigned int p3 = 255U;
            dst_row[full_quads] = (p0 << 24) | (p1 << 16) | (p2 << 8) | p3;
        }
    }

    return pix;
}

void st_pix_destroy(Pix * _Nullable pix) {
    if (pix) {
        Pix *p = pix;
        pixDestroy(&p);
    }
}
