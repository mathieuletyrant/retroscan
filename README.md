# 📸 retroscan

A macOS CLI (Swift, zero dependencies, zero drivers) that scans from a
networked Brother printer, auto-crops each photo, puts them upright, and
embeds metadata — built for digitizing whole albums of old photo prints.

Tested with a Brother MFC-1910W. Works with any Brother device exposing the
`_scanner._tcp` Bonjour service (port 54921, the protocol behind the SANE
`brscan` backends) — **no Brother driver needed**, even on macOS versions
where none exists anymore.

## ✨ What it does

- 🖨️ **Driverless scanning** — speaks the Brother network scan protocol directly
- ✂️ **Multi-photo cropping** — lay several prints on the glass, get one tight
  file per photo (paper borders shaved off)
- 🔄 **Auto-rotation** — face detection puts people the right way up
- 🏷️ **Metadata** — original shooting date, title, keywords, author, scanner
  model, DPI, all embedded in EXIF/IPTC/TIFF
- 🔘 **Watch mode** — press the printer's Scan button, the Mac does the rest
- 🧠 **Optional Segment Anything** — SAM 2 on the Neural Engine for photos
  whose edges are nearly white

## 🚀 Install

```sh
make build       # swift build -c release + sudo cp to /usr/local/bin
```

## 🎯 Usage

```sh
retroscan                          # color 300 dpi scan, auto-crop, current dir
retroscan --list                   # list scanners on the network
retroscan -r 600 -m gray -o ~/Documents/Scans
retroscan -t "Holidays 1995" -D 1995 -k photos,family -a "Mathieu"
retroscan -c photos                # force one-file-per-photo splitting
retroscan -R none                  # disable auto-rotation
retroscan --input page.jpg         # re-run crop/rotate/metadata on an existing scan
```

`retroscan --help` shows every option.

With `--title` (or `--name`), files come out as `Holidays 1995-1.jpg`,
`-2.jpg`, … and **numbering continues from one run to the next** in the same
folder: perfect for digitizing an album a few prints at a time. Without a
title, each run gets a timestamped `scan-<timestamp>` base.

## 🔘 Watch mode: scan from the printer's button

```sh
retroscan watch -t "1995" -D 1995 -o ~/Documents/Scans/1995
```

The Mac registers itself on the device's **Scan to PC** menu (the
`brscan-skey` protocol: an SNMP registration plus a UDP callback). Then:
lay photos on the glass → press the printer's **Scan** button → pick
*retroscan* on its LCD → files appear on the Mac, numbered in sequence.
You never touch the computer during a scanning session.

## ✂️ What `auto` cropping does

1. Several photos on the bed → region detection (luminance + gradient
   masks, connected components) and **one file per photo**, split along
   any narrow bed-white seam when prints are laid almost touching.
2. A single detected document → Vision perspective crop.
3. Otherwise → plain white-border trim.

Multiple pages from the ADF come out as `-p1`, `-p2`, … files.

## 🔄 Auto-rotation

`--rotate auto` (default): Vision face detection in all four orientations,
weighted by face roll angle — photos of people come out upright. Photos with
no detectable face are left as scanned. `--rotate 90|180|270` forces a
clockwise rotation, `none` disables.

## 🏷️ Embedded metadata

Always: scan date (EXIF DateTimeDigitized), scanner make/model and software
(TIFF), DPI. Optional: `--title` (IPTC ObjectName), `--keywords` (IPTC),
`--author` (TIFF Artist + IPTC Byline), `--description` (EXIF UserComment +
TIFF ImageDescription + IPTC Caption), and `--date` — when the photo was
**taken** (`1995`, `1995-07` or `1995-07-14`), written to EXIF
DateTimeOriginal + IPTC DateCreated: the field Apple Photos, Google Photos
and Lightroom sort by.

## 🧠 Segment Anything (SAM 2) on Apple silicon

```sh
retroscan --sam        # downloads Apple's Core ML models (~78 MB, once)
```

With `--sam`, photo detection is powered by **Segment Anything 2** (Apple's
official Core ML conversion, running on the GPU/Neural Engine). The
classical detection roughly locates each print, then SAM traces its true
outline — including edges invisible to any threshold, like a washed-out sky
or a white tablecloth against the bed white. Models are cached in
`~/Library/Application Support/retroscan/`.

It's a rescue mode, not the default: SAM's 256×256 mask quantizes edges to
~7 px on an A4 page at 300 dpi, so the classical luminance+gradient
detection usually crops tighter. Reach for `--sam` when a pale-edged photo
gets miscropped — or use the dark sheet trick below.

## 🖤 Tip: photos with near-white edges

A print whose edge is itself nearly white (washed-out sky, white
tablecloth…) can be indistinguishable from the scanner bed. The bulletproof
fix costs nothing: lay a **dark sheet of paper** over the photos before
closing the lid, covering the whole glass. retroscan detects the background
level automatically and the crop becomes trivial, white edges included.

`RETROSCAN_DEBUG=1 retroscan …` prints the detected background level and
regions — handy with `--input file.jpg` to replay a surprising crop without
touching the scanner.

## 🔌 Protocol notes (MFC-1910W)

- Banner `+OK 200` on connecting to TCP 54921.
- Query: `ESC I \n R=x,y \n M=mode \n 0x80` → `0x00 <len:2 LE> <csv> 0x00`
  (resolution, width mm/px, height mm/px).
- Scan: `ESC X` with `M=CGRAY` (= **24-bit color** JPEG, counter-intuitively),
  `C=JPEG`, `A=0,0,w,h`, `D=SIN`. The hardware gray mode (`GRAY64`) uses an
  RLE encoding — gray output is produced locally instead.
- Stream: `0x64` blocks (12-byte header, length at bytes 10-11 LE, JPEG
  payload), `0x82` end of page, `0x80` end of session, `0xc2` feeder empty,
  `0xc3` paper jam, `0xc4` cover open.
- Scan button: SNMPv1 SET (community `internal`, OID
  `1.3.6.1.4.1.2435.2.3.9.2.11.1.1.0`) registers the host; the device then
  sends a UDP datagram to the advertised port on each button press.
- ⚠️ An invalid scan command (e.g. `M=C24BIT`, a family-5 mode) wedges the
  printer's scan service for about a minute.

## 🙏 Credits

- Protocol details cross-checked against the in-progress
  [`brother_mfp` SANE backend](https://gitlab.com/sane-project/backends/-/merge_requests/751).
- SAM 2 Core ML models by [Apple on Hugging Face](https://huggingface.co/apple/coreml-sam2-tiny)
  (Apache-2.0), integration informed by [sam2-studio](https://github.com/huggingface/sam2-studio).
