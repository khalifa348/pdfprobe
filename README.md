# PDFProbe

Defensive QA / fuzzing harness for **on-device PDF parsing + rasterization**
robustness testing on the user's own jailbroken device (tested iPhone 18,2 /
iOS 26.6). Mirrors the proven [SpeechProbe](../speechprobe) architecture.

PDFKit needs **no special runtime permission** (no mic, no speech) — the app
just watches `Documents/In`, parses + rasterizes each arriving PDF, logs every
stage to OSLog, and moves the finished file to `Documents/Out`.

## How it works

On launch the app:

1. Creates `Documents/In` and `Documents/Out` (under the app container).
2. Bootstraps any files already present in `Documents` / `Documents/In`, then
   starts a `DispatchSourceFileSystemObject` watch on `Documents/In` for new arrivals.
3. Processes each file **sequentially** through a per-file pipeline:

```
PDF_START <name>
  CGPDFDocument(url) created?
    NO  -> PDF_ERR <name>:<reason>  ; move to Out ; continue
    YES -> PDF_PAGES <name>:<n>
  for each page:
    render into CGBitmapContext @72dpi (1pt == 1px)
      -> PDF_RENDER <name>:<page> pts=WxH px=WxH
  CGPDFDocumentGetCatalog + CGPDFDocumentGetInfo (trailer dict)
    -> PDF_TRAILER <name>:catalog=[keys] info=[keys]
PDF_DONE <name>  ; move to Out
```

- **60s hang guard** per file: `DispatchQueue`+`asyncAfter` watchdog
  (`HangGuard`) logs `PDF_HANG <name>` and forces the queue to continue if a
  single file never completes in time.
- **OSLog** subsystem `com.khalifa.pdfprobe`; all markers emitted via
  `os.Logger`. Also mirrored into an in-app on-screen log (500 line cap).
- Files are moved to `Documents/Out` as they finish; on move failure a copy
  is attempted (best effort).

### Marker reference

| Marker | Meaning |
|--------|---------|
| `PDF_START <name>` | Processing began |
| `PDF_PAGES <name>:<n>` | Document opened; page count is `n` |
| `PDF_RENDER <name>:<p> ...` | Page `p` rasterized at 72 dpi |
| `PDF_TRAILER <name>:catalog=[...] info=[...]` | Trailer/catalog dict keys |
| `PDF_DONE <name>` | All pages rendered; moving to Out |
| `PDF_ERR <name>:<reason>` | Document creation failed |
| `PDF_HANG <name>` | 60s watchdog fired on this file |
| `PDF_MOVED <name> -> Out` / `PDF_MOVE_ERR <name>` | File relocation outcome |

## Frameworks / runtime

- Frameworks: **SwiftUI, PDFKit, CoreGraphics, UIKit, os.log, Foundation**
  (PDFKit is a thin wrapper over CoreGraphics' CGPDFDocument).
- Deployment target **iOS 15.0**, Swift 5. Conservative, modern — device runs
  iOS 26.6 so everything is available.
- No third-party dependencies.

## Requirements

- macOS with Xcode (CI) **or** local Xcode for dev builds
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`)
- [Sideloadly](https://sideloadly.io/) for unsigned-IPA install (or AltStore),
  and/or a method to push files into the app container
  ([pymobiledevice3](https://github.com/doronz88/pymobiledevice3) house_arrest)
- The host machine's device credential/lockdown pairing for `pymobiledevice3`
  crash collection: `pymobiledevice3 dvt crash ls`

## Build (GitHub Actions — recommended)

1. Push this repo (or mirror the `Sources/`, `project.yml` and
   `.github/workflows/build-ios.yml`) to GitHub.
2. Open **Actions → Build PDFProbe (unsigned IPA)** → **Run workflow**.
3. Download the `PDFProbe-unsigned-ipa` artifact (`PDFProbe-unsigned.ipa`).

## Build (local)

```bash
cd pdfprobe
xcodegen generate          # produces PDFProbe.xcodeproj
xcodebuild \
  -project PDFProbe.xcodeproj \
  -scheme PDFProbe \
  -configuration Release \
  -destination "generic/platform=iOS" \
  -derivedDataPath build \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY="" DEVELOPMENT_TEAM="" \
  build
# .ipa (optional):
mkdir -p out/Payload && cp -R build/Build/Products/Release-iphoneos/*.app out/Payload/
cd out && zip -r -y ../PDFProbe-unsigned.ipa Payload
```

## Install (Sideloadly)

1. Drag `PDFProbe-unsigned.ipa` into Sideloadly.
2. Select your iPhone, use your Apple ID (a free account works fine; the app
   needs no entitlements).
3. Install, then **trust the developer** in Settings → General → VPN & Device
   Management.
4. Launch **PDFProbe**.

## Push test files & watch results

Push PDFs into the app's container with `pymobiledevice3`:

```bash
# apps_container returns the app container path for the installed bundle
CONTAINER=$(pymobiledevice3 apps find com.khalifa.pdfprobe --json | python3 -c "import sys,json;print(json.load(sys.stdin)['data_container'])")
# or use house_arrest to push
pymobiledevice3 apps push com.khalifa.pdfprobe /host/path/corpus.pdf Documents/In/
```

The watch loop picks each file up within a moment and logs the markers.

To pull observed crashes (any stage that panics the renderer/parser):

```bash
pymobiledevice3 dvt crash ls
pymobiledevice3 dvt crash show <uuid>
```

## Config notes (`project.yml`)

- Bundle id: `com.khalifa.pdfprobe`
- `UIFileSharingEnabled: true` + `LSSupportsOpeningDocumentsInPlace: true` so
  the container is addressable for pushing files in place.
- No `NSMicrophoneUsageDescription`/`NSSpeechRecognitionUsageDescription` —
  PDFKit requires none.
- Unsigned build flags (`CODE_SIGNING_ALLOWED=NO` etc.) mirror SpeechProbe and
  produce a Sideloadly-installable unsigned IPA.
