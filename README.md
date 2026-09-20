# Xelated

Transfer photos from a directory to different external drives and Android phones.

Xelated is a small macOS utility for getting a folder of photos and videos onto an
external drive and/or an Android phone, so the phone's own backup app can pick them up
and send them to the cloud from there.

## What it does

- **Scans a source folder** for photos and videos, reading capture dates from EXIF (or
  falling back sensibly when that's missing).
- **Backs up to an external drive.** Files are copied into `YYYY/YYYY-MM/` folders by
  capture date. Nothing already at the destination is touched, overwritten, or
  duplicated — safe to point at a drive that already has files on it, and safe to run
  again.
- **Backs up to a connected Android phone over USB**, as a staging step before whatever
  backup app you already have set up on the phone takes it from there. Batches are sized
  to fit the phone's free space with headroom to spare, pushed over `adb`, and only
  cleared off the phone once you confirm the phone's own backup has actually picked them
  up — there's no way for a Mac app to know that for certain, so it's always your call.
- Keeps a durable, crash-safe record of what's been sent where, so re-running a backup
  never duplicates work, and an interrupted run can pick back up where it left off.
- An explicit "upload again" option if you ever want to force a re-send regardless of
  what's already been recorded.

## How it works

1. Choose a source folder (for example, one exported from an iPhone via Image Capture).
2. Choose one or both destinations: an external drive folder, and/or a connected Android
   phone.
3. Run the backup. Drive backups run straight through; phone backups pause after each
   batch so you can confirm the phone's backup app has finished with it before the next
   batch goes over.

## Requirements

- macOS 27 or later.
- For phone backups: [Android Platform Tools](https://developer.android.com/tools/releases/platform-tools)
  (`adb`), e.g. `brew install android-platform-tools`, and USB debugging enabled on the
  phone.

## Status

Actively developed for personal use, not a polished release. Source folders currently
come from Finder — there's no direct iPhone device import yet. Deleting originals from
the source after a verified backup isn't implemented either.

## Testing

`xelatedTests` covers the scanning, ledger, drive-backup, and batching logic with Swift
Testing, without needing any hardware attached.
