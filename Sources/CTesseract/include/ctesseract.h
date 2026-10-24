#ifndef SCANTAILOR_CTESSERACT_H
#define SCANTAILOR_CTESSERACT_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// MARK: - Opaque Tesseract & Leptonica Handles

typedef struct TessBaseAPI TessBaseAPI;
typedef struct TessResultIterator TessResultIterator;
typedef struct TessPageIterator TessPageIterator;
typedef struct TessChoiceIterator TessChoiceIterator;
typedef struct ETEXT_DESC ETEXT_DESC;
typedef struct Pix Pix;

// MARK: - Enumerations

typedef enum TessOcrEngineMode {
    OEM_TESSERACT_ONLY = 0,
    OEM_LSTM_ONLY = 1,
    OEM_TESSERACT_LSTM_COMBINED = 2,
    OEM_DEFAULT = 3
} TessOcrEngineMode;

typedef enum TessPageSegMode {
    PSM_OSD_ONLY = 0,
    PSM_AUTO_OSD = 1,
    PSM_AUTO_ONLY = 2,
    PSM_AUTO = 3,
    PSM_SINGLE_COLUMN = 4,
    PSM_SINGLE_BLOCK_VERT_TEXT = 5,
    PSM_SINGLE_BLOCK = 6,
    PSM_SINGLE_LINE = 7,
    PSM_SINGLE_WORD = 8,
    PSM_CIRCLE_WORD = 9,
    PSM_SINGLE_CHAR = 10,
    PSM_SPARSE_TEXT = 11,
    PSM_SPARSE_TEXT_OSD = 12,
    PSM_RAW_LINE = 13,
    PSM_COUNT = 14
} TessPageSegMode;

typedef enum TessPageIteratorLevel {
    RIL_BLOCK = 0,
    RIL_PARA = 1,
    RIL_TEXTLINE = 2,
    RIL_WORD = 3,
    RIL_SYMBOL = 4
} TessPageIteratorLevel;

// MARK: - Tesseract C API Declarations

const char * _Nonnull TessVersion(void);

void TessDeleteText(const char * _Nullable text);
void TessDeleteTextArray(char * _Nullable * _Nullable arr);
void TessDeleteIntArray(const int * _Nullable arr);

TessBaseAPI * _Nullable TessBaseAPICreate(void);
void TessBaseAPIDelete(TessBaseAPI * _Nullable handle);

int TessBaseAPIInit2(
    TessBaseAPI * _Nonnull handle,
    const char * _Nullable datapath,
    const char * _Nullable language,
    TessOcrEngineMode oem
);

int TessBaseAPIInit3(
    TessBaseAPI * _Nonnull handle,
    const char * _Nullable datapath,
    const char * _Nullable language
);

const char * _Nullable TessBaseAPIGetInitLanguagesAsString(const TessBaseAPI * _Nonnull handle);
char * _Nullable * _Nullable TessBaseAPIGetLoadedLanguagesAsVector(const TessBaseAPI * _Nonnull handle);
char * _Nullable * _Nullable TessBaseAPIGetAvailableLanguagesAsVector(const TessBaseAPI * _Nonnull handle);
const char * _Nullable TessBaseAPIGetDatapath(TessBaseAPI * _Nonnull handle);

void TessBaseAPISetPageSegMode(TessBaseAPI * _Nonnull handle, TessPageSegMode mode);
TessPageSegMode TessBaseAPIGetPageSegMode(const TessBaseAPI * _Nonnull handle);

int TessBaseAPISetVariable(
    TessBaseAPI * _Nonnull handle,
    const char * _Nonnull name,
    const char * _Nonnull value
);

void TessBaseAPISetImage(
    TessBaseAPI * _Nonnull handle,
    const unsigned char * _Nonnull imagedata,
    int width,
    int height,
    int bytes_per_pixel,
    int bytes_per_line
);

void TessBaseAPISetImage2(TessBaseAPI * _Nonnull handle, Pix * _Nonnull pix);
void TessBaseAPISetSourceResolution(TessBaseAPI * _Nonnull handle, int ppi);

int TessBaseAPIRecognize(TessBaseAPI * _Nonnull handle, ETEXT_DESC * _Nullable monitor);
TessResultIterator * _Nullable TessBaseAPIGetIterator(TessBaseAPI * _Nonnull handle);
char * _Nullable TessBaseAPIGetUTF8Text(TessBaseAPI * _Nonnull handle);
int TessBaseAPIMeanTextConf(TessBaseAPI * _Nonnull handle);

void TessBaseAPIClear(TessBaseAPI * _Nonnull handle);
void TessBaseAPIEnd(TessBaseAPI * _Nonnull handle);

// MARK: - Result & Page Iterators

void TessResultIteratorDelete(TessResultIterator * _Nullable handle);
int TessResultIteratorNext(TessResultIterator * _Nonnull handle, TessPageIteratorLevel level);
TessPageIterator * _Nullable TessResultIteratorGetPageIterator(TessResultIterator * _Nonnull handle);
const TessPageIterator * _Nullable TessResultIteratorGetPageIteratorConst(const TessResultIterator * _Nonnull handle);
char * _Nullable TessResultIteratorGetUTF8Text(
    const TessResultIterator * _Nonnull handle,
    TessPageIteratorLevel level
);
float TessResultIteratorConfidence(
    const TessResultIterator * _Nonnull handle,
    TessPageIteratorLevel level
);
const char * _Nullable TessResultIteratorWordRecognitionLanguage(
    const TessResultIterator * _Nonnull handle
);

int TessPageIteratorBoundingBox(
    const TessPageIterator * _Nonnull handle,
    TessPageIteratorLevel level,
    int * _Nonnull left,
    int * _Nonnull top,
    int * _Nonnull right,
    int * _Nonnull bottom
);

int TessPageIteratorBaseline(
    const TessPageIterator * _Nonnull handle,
    TessPageIteratorLevel level,
    int * _Nonnull x1,
    int * _Nonnull y1,
    int * _Nonnull x2,
    int * _Nonnull y2
);

// MARK: - Leptonica Pix C API Declarations

Pix * _Nullable pixCreate(int width, int height, int depth);
void pixDestroy(Pix * _Nullable * _Nonnull ppix);
int pixSetResolution(Pix * _Nonnull pix, int xres, int yres);
unsigned int * _Nullable pixGetData(Pix * _Nonnull pix);
int pixGetWpl(const Pix * _Nonnull pix);
int pixGetWidth(const Pix * _Nonnull pix);
int pixGetHeight(const Pix * _Nonnull pix);
int pixGetDepth(const Pix * _Nonnull pix);
int pixGetPixel(Pix * _Nonnull pix, int x, int y, unsigned int * _Nonnull pval);
int pixSetPixel(Pix * _Nonnull pix, int x, int y, unsigned int val);
char * _Nullable getLeptonicaVersion(void);
void lept_free(void * _Nullable ptr);

// MARK: - ScanTailor Fast Raster -> Leptonica Pix Conversion Helpers

/// Creates a 1-bit Leptonica `Pix` from ScanTailor's MSB-packed 64-bit `BinaryBitmap` words.
///
/// Both `BinaryBitmap` and Leptonica 1-bpp `Pix` use `1` for black foreground ink and `0` for
/// white background paper, with the leftmost pixel in the most significant bit of each word.
/// The caller owns the returned `Pix` and must release it via `st_pix_destroy`.
Pix * _Nullable st_pix_create_from_binary_words(
    int width,
    int height,
    int dpi,
    const uint64_t * _Nonnull words,
    int words_per_row
);

/// Creates an 8-bit Leptonica `Pix` from ScanTailor's planar 8-bit `GrayscaleBuffer` pixels.
///
/// Both `GrayscaleBuffer` and Leptonica 8-bpp `Pix` use `0` for black and `255` for white.
/// Each 32-bit word in Leptonica `Pix` packs 4 horizontal pixels in MSB-first order.
/// The caller owns the returned `Pix` and must release it via `st_pix_destroy`.
Pix * _Nullable st_pix_create_from_grayscale_bytes(
    int width,
    int height,
    int dpi,
    const uint8_t * _Nonnull pixels,
    int row_bytes
);

/// Safely destroys a Leptonica `Pix` instance.
void st_pix_destroy(Pix * _Nullable pix);

#ifdef __cplusplus
}
#endif

#endif /* SCANTAILOR_CTESSERACT_H */
