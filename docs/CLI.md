# LocalSend CLI

The LocalSend backend can be used as a standalone command-line tool without KOReader.

## Building

```bash
go build -o localsend
```

### Cross-compiling for ARM devices

```bash
# Full build (compile Go + package into release zips)
./arm_build.sh

# Package only (skip Go compilation, reuse existing binaries)
./arm_build.sh --package
```

Or build manually:

```bash
# armv7 (32-bit)
GOOS=linux GOARCH=arm GOARM=7 CGO_ENABLED=0 go build -ldflags="-s -w" -o localsend

# arm64 (64-bit)
GOOS=linux GOARCH=arm64 CGO_ENABLED=0 go build -ldflags="-s -w" -o localsend
```

## Receiving Files

```bash
# Basic receive mode
./localsend recv -d ~/Downloads

# With device name and PIN
./localsend recv -d ~/Downloads -n "My Server" -p 1234

# Filter by file type
./localsend recv -d ~/Downloads -a epub,pdf,mobi

# With extension routing
./localsend recv -d ~/Downloads --ext-routing routing.json
```

## CLI Flags

| Flag | Description |
| ---- | ----------- |
| `-d, --dir` | Save directory for received files |
| `-n, --devname` | Device name advertised on the network |
| `-p, --pin` | PIN code required for transfers |
| `-a, --accept-ext` | Comma-separated list of allowed extensions |
| `--ext-routing` | Path to extension routing config (JSON) |
| `--https` | Enable HTTPS (default: true) |
| `-w, --webrtc` | Enable WebRTC/v3 protocol (default: true) |
| `-l, --log` | Path to transfer log file (JSON lines format) |

## Extension Routing

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

### Example Configurations

**E-reader focused (strict - only accept specific types):**
```json
{
  "epub": "/mnt/us/documents/Books",
  "pdf": "/mnt/us/documents/PDFs",
  "mobi": "/mnt/us/documents/Books",
  "azw3": "/mnt/us/documents/Books"
}
```

**General purpose (accept all, route specific types):**
```json
{
  "epub": "/home/user/Books",
  "pdf": "/home/user/Documents",
  "mp3": "/home/user/Music",
  "default": "/home/user/Downloads"
}
```
