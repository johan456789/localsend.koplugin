## LocalSend for KOReader

A KOReader plugin that enables receiving files from other devices using the [LocalSend](https://localsend.org/) protocol. Send ebooks, documents, and other files directly to your e-reader from any device running LocalSend.

**[Download latest release](https://github.com/kaikozlov/localsend.koplugin/releases/latest)**

### Features

- **Receive files wirelessly** - Accept files from phones, tablets, and computers running LocalSend
- **WebRTC support** - Works with the latest LocalSend v3 protocol (opt-in)
- **File type filtering** - Accept only specific file types (epub, pdf, mobi, etc.) or allow all
- **PIN protection** - Optionally require a PIN code for incoming transfers
- **HTTPS support** - Secure file transfers with TLS encryption
- **Auto-start** - Optionally start the server automatically when KOReader launches
- **Transfer notifications** - Get notified when files are received
- **Custom device name** - Set a recognizable name for your device on the network

### Installation

1. Download the latest release for your device's architecture:
   - **armv7** - 32-bit ARM (e.g., Kindle Paperwhite 12)
   - **arm64** - 64-bit ARM
2. Extract `localsend.koplugin` to your KOReader plugins directory:
   - Kindle: `/mnt/us/koreader/plugins/`
   - Kobo: `/.adds/koreader/plugins/`
   - Other devices: Check your KOReader installation path
3. Restart KOReader

### Usage

1. Open KOReader and go to **Menu > Network > LocalSend**
2. Configure your settings:
   - **Save directory** - Where received files will be stored
   - **Device name** - How your device appears to senders (leave empty for random name)
   - **Allowed extensions** - Filter incoming files by type
   - **PIN code** - Optional security for transfers
3. Tap **Start server** to begin receiving files
4. On your phone/computer, open LocalSend and send files to your e-reader

### Settings

| Setting             | Description                                     |
| ------------------- | ----------------------------------------------- |
| Save directory      | Destination folder for received files           |
| Device name         | Display name on the network (e.g., "My Kindle") |
| Allowed extensions  | Comma-separated list of accepted file types     |
| File type routing   | Route files to different directories by type    |
| PIN code            | Required PIN for incoming transfers (optional)  |
| Use HTTPS           | Enable TLS encryption (recommended)             |
| Use WebRTC          | Enable v3 protocol for latest LocalSend apps    |
| Start with KOReader | Auto-start server on launch                     |

### How It Works

This plugin uses a lightweight LocalSend CLI implementation as its backend. The CLI handles both LocalSend v2 and v3 protocols including:

- Multicast UDP device discovery
- HTTPS/HTTP file transfer server
- WebRTC signaling and data transfer (v3)
- Certificate generation and management

The KOReader frontend provides the user interface, settings management, and integrates with KOReader's file browser and notification system.

### Building the Backend

The backend CLI is written in Go. To build for ARM devices:

```bash
# Full build (compile Go + package into release zips)
./arm_build.sh

# Package only (skip Go compilation, reuse existing binaries)
# Useful when you've only changed Lua code
./arm_build.sh --package
```

Or build manually:

```bash
# armv7 (32-bit)
GOOS=linux GOARCH=arm GOARM=7 CGO_ENABLED=0 go build -ldflags="-s -w" -o localsend

# arm64 (64-bit)
GOOS=linux GOARCH=arm64 CGO_ENABLED=0 go build -ldflags="-s -w" -o localsend
```

### Compatibility

Tested on Kindle Paperwhite 12 (armv7). Should work on other devices supported by KOReader - just download the correct architecture (armv7 or arm64) for your device.

### Which architecture do I need?

| Architecture | Devices                                             |
| ------------ | --------------------------------------------------- |
| **armv7**    | Kindle, Kobo (all models), reMarkable 2, PocketBook |
| **arm64**    | reMarkable Paper Pro                                |

> **Kindle users:** This plugin works best with firmware 5.16.3 or newer. Older firmware versions may also work as of v1.0.7 — give it a try!

**Not sure?** Try armv7 first.

_Reported_ to work on:

armv7 devices:

- Kindle Paperwhite 12th Gen (PW6)
- Kindle Paperwhite 11th Gen (PW5/SE)
- Kindle Paperwhite 10th Gen (PW4)
- Kindle Basic 11th Gen
- Kindle Basic 10th Gen
- Kindle Oasis
- Kindle Colorsoft 32GB
- Kindle Scribe 1st Gen
- Kobo Clara Colour
- Kobo Forma
- Kobo Libra Colour
- Kobo Aura N236

### License

MIT License

---

## Standalone CLI Usage

The backend can also be used as a standalone command-line tool without KOReader.

### Building

```bash
go build -o localsend
```

### Receiving Files

```bash
# Basic receive mode
./localsend recv -d ~/Downloads

# With device name and PIN
./localsend recv -d ~/Downloads -n "My Server" -p 1234

# Filter by file type
./localsend recv -d ~/Downloads -a epub,pdf,mobi

# With extension routing (route files to different directories)
./localsend recv -d ~/Downloads --ext-routing routing.json
```

### CLI Flags

| Flag             | Description                                      |
| ---------------- | ------------------------------------------------ |
| `-d, --dir`      | Save directory for received files                |
| `-n, --devname`  | Device name advertised on the network            |
| `-p, --pin`      | PIN code required for transfers                  |
| `-a, --accept-ext` | Comma-separated list of allowed extensions     |
| `--ext-routing`  | Path to extension routing config (JSON)          |
| `--https`        | Enable HTTPS (default: true)                     |
| `-w, --webrtc`   | Enable WebRTC/v3 protocol (default: true)        |
| `-l, --log`      | Path to transfer log file (JSON lines format)    |

### Extension Routing

Extension routing lets you save different file types to different directories. Create a JSON file with extension-to-directory mappings:

```json
{
  "epub": "/home/user/Books",
  "pdf": "/home/user/Documents",
  "mobi": "/home/user/Books",
  "cbz": "/home/user/Comics",
  "default": "/home/user/Downloads"
}
```

**Format:**
- Keys are lowercase file extensions (without the dot)
- Values are absolute directory paths
- The special `"default"` key specifies where unrouted files go
- If `"default"` is omitted, unrouted files are rejected

**Usage:**
```bash
./localsend recv -d ~/Downloads --ext-routing ~/routing.json
```

**Example configurations:**

*E-reader focused (strict - only accept specific types):*
```json
{
  "epub": "/mnt/us/documents/Books",
  "pdf": "/mnt/us/documents/PDFs",
  "mobi": "/mnt/us/documents/Books",
  "azw3": "/mnt/us/documents/Books"
}
```

*General purpose (accept all, route specific types):*
```json
{
  "epub": "/home/user/Books",
  "pdf": "/home/user/Documents",
  "mp3": "/home/user/Music",
  "default": "/home/user/Downloads"
}
```
