# Development

## Setup

- macOS 14 or later, Xcode 16 or later (Swift 6).
- `brew install tesseract` (which pulls in Leptonica); `brew install tesseract-lang` for Greek, Latin and Fraktur.
- `swift build -c release -Xswiftc -enable-testing`. Use these flags for CLI runs too, so the tests and the CLI share one build.

## Conventions

- Swift 6 language mode with strict concurrency. Value types first; `Sendable` across tasks.
- Swift Testing (`@Suite`, `@Test`, `#expect`), not XCTest.
- DocC comments on public API.
- New manifest and configuration fields decode with `decodeIfPresent`, so existing manifests keep loading.
- Manual overrides beat automatic detection (see [ARCHITECTURE.md](ARCHITECTURE.md#design-rules)).
- When adding a CLI flag in `parseProcessOptions`, every `case` must advance `i`, or the parser loops forever.

## Tests

Release builds run the image loops about 80 times faster than debug builds. Use [`scripts/test.sh`](../scripts/test.sh):

| Command | What it runs |
| :--- | :--- |
| `scripts/test.sh fast [filter]` | The whole suite in release: about a minute including the build. |
| `scripts/test.sh corpus [filter]` | The same, plus the real-book tests (`SCANTAILOR_CORPUS_DIR`, defaulting to the OneDrive library below). |
| `scripts/test.sh debug [filter]` | The debug suite: slow (10–30 min), but it keeps the `assert` bounds checks in the `BinaryBitmap` and `GrayscaleBuffer` subscripts. Run it occasionally in the background before a release. |

The unit tests make their own PDFs and bitmaps and need no files. Opt-in suites read real scans:

- **`RealCorpusTests`** (`SCANTAILOR_CORPUS_DIR`): short excerpts from flannery.1993, gury.1866, vermeersch.1934, long.2015, SLE.2 and pilsner.2006.
- **`CameraGutterCorpusTests`** (`SCANTAILOR_CORPUS_DIR`): the Simpson 1968 phone photos.
- **`BenchmarkTests`** (`SCANTAILOR_BENCHMARK=1` plus `SCANTAILOR_CORPUS_DIR`): end-to-end runs of Flannery 1993, Vermeersch 1934 and Simpson 1968, scored against the layout checks. `SCANTAILOR_BENCHMARK_OUT` names the folder for the JSON scorecards. Vermeersch is also scored with its small adjustments file.

  ```bash
  SCANTAILOR_CORPUS_DIR="$HOME/Library/CloudStorage/OneDrive-MRC/PDFs-in-the-making" \
    SCANTAILOR_BENCHMARK=1 swift test -c release -Xswiftc -enable-testing --filter BenchmarkTests
  ```

## Corpus

The real books are kept outside the repository, in `~/Library/CloudStorage/OneDrive-MRC/PDFs-in-the-making/<book>/`:

- `00-pdf-orig/` (occasionally `00-jpeg-orig/`) holds the source scans.
- `03-pdf-out/` holds the user's finished PDFs, which serve as layout ground truth.

A reference PDF can itself be wrong. SLE.2's lectio openings hang from the top there, but they should sit on the bottom. When a reference and the layout rules disagree, ask.

| Book | What it tests |
| :--- | :--- |
| flannery.1993 | Clean journal scan: JSTOR cover, tracking footers, blank pages. |
| vermeersch.1934 | Photocopied spreads: dark crease, binding warp, title page beside a blank half. |
| simpson.1968 | Hand-held phone photos at 72 DPI: perspective, curl, desk, uneven light. |
| long.2015 | Fore-edge page stacks, running headers. |
| SLE.2 | Landscape table scan, narrow lectio openings. |
| gury.1866, pilsner.2006 | Headers with a large gap; a thumbnail cover. |

When a stage misbehaves on a book, run `process … --diagnostics-dir d/ --all-diagnostics`. Then read `d/<stem>-lines.json` for the detected lines and anchors.

## Agent skill and plugin

The canonical skill is [plugins/scantailor-reborn/skills/scantailor-reborn/SKILL.md](../plugins/scantailor-reborn/skills/scantailor-reborn/SKILL.md). After editing it, run [`scripts/sync-skill.sh`](../scripts/sync-skill.sh) to mirror it into `.claude/skills/` and `.agents/skills/`. `.claude/skills/` is for Claude Code and `.agents/skills/` is for Antigravity. Both mirrors are tracked, but everything else in those folders is git-ignored. `scripts/test.sh` runs `scripts/sync-skill.sh --check` first and fails if a mirror differs from the canonical file. The plugin marketplace is [.claude-plugin/marketplace.json](../.claude-plugin/marketplace.json).

When the CLI's options change, update `usageText`, the README's option tables and the skill together. Every flag in `--help` must appear in the README.

The skill ships in this repository, not a separate one, so that the tool and its documentation of the tool are tagged together. Its plugin version (`version` in [plugin.json](../plugins/scantailor-reborn/.claude-plugin/plugin.json)) always equals the release version.

## Releasing

1. Update [CHANGELOG.md](../CHANGELOG.md), noting any change to the skill. Set `version` in [plugin.json](../plugins/scantailor-reborn/.claude-plugin/plugin.json) to the new version, and run `scripts/sync-skill.sh` if the skill changed. Then commit and push.
2. Tag the release and push the tag: `git tag vX.Y.Z && git push origin vX.Y.Z`.
3. In the tap repository [`AthanasiusOfAlex/homebrew-scantailor-reborn`](https://github.com/AthanasiusOfAlex/homebrew-scantailor-reborn), update `Formula/scantailor-reborn.rb`:
   - Set `url` to the new tag's tarball.
   - Set `sha256` to the output of `curl -sfL <url> | shasum -a 256`. The repository must be public, or the hash will be that of a 404 page.
4. Verify the formula:
   ```bash
   brew trust AthanasiusOfAlex/scantailor-reborn      # once; recent Homebrew refuses untrusted taps
   brew install --build-from-source scantailor-reborn  # about a minute
   brew test scantailor-reborn
   brew audit --strict scantailor-reborn
   ```
   The formula builds with `swift build --disable-sandbox -c release`. It depends on `tesseract`, Xcode 16 at build time and macOS Sonoma.
5. Push the tap.
