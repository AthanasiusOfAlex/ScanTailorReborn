# Resume Prompt (Copy & Paste into New Session)

```text
We are resuming development of ScanTailorReborn on a new Mac.

1. Read `docs/HANDOFF.md` in full and review the Phases 4–7 roadmap in `docs/WHITE_PAPER.md` (lines 250–417).
2. Run `swift build` to confirm the toolchain and Homebrew `tesseract`/`leptonica` libraries are linked properly on this machine.
3. Complete **Substep 4.1.1: Automatic Font-Scale Heuristic & Median Glyph Height Analyzer** following the verified mathematical invariants, scope boundaries, and 5-step file checklist in `docs/HANDOFF.md` Section 3 (`PDFSourceReader.pageBoxPoints(at:)` is already committed).
4. Run `swift test` until 100% of existing and new tests pass with zero warnings, then report the results and wait before moving to Substep 4.1.2.
```
