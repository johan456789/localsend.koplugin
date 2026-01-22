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

## Scanning for Devices

```bash
# Scan for LocalSend devices on the network
./localsend scan

# Scan with JSON output (for scripting)
./localsend scan --json

# Scan only LAN devices
./localsend scan --lan

# Scan with custom timeout
./localsend scan -t 10
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

## Sending Files

```bash
# Send to a LAN device by IP
./localsend send --ip 192.168.1.50 myfile.epub

# Send via WebRTC (use ID from scan --json)
./localsend send -w --target <peer-uuid> myfile.epub

# Send with PIN
./localsend send --ip 192.168.1.50 -p 1234 myfile.epub

# Send a directory (preserves structure)
./localsend send --ip 192.168.1.50 ./my-folder/

# Send with custom device name
./localsend send --ip 192.168.1.50 -n "My Computer" myfile.epub
```

## CLI Flags

### recv command

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
| `--on-transfer` | Shell command to run after each transfer |
| `--config-dir` | Config directory for trusted devices |
| `--require-pairing` | Require PAIR before accepting WebRTC transfers |
| `--stun-servers` | Custom STUN servers for WebRTC |
| `--signaling-id-file` | Write WebRTC signaling ID to file |

### send command

| Flag | Description |
| ---- | ----------- |
| `--ip` | Target device IP address |
| `-f, --file` | File or directory to send |
| `-p, --pin` | PIN code for authentication |
| `-n, --devname` | Device name shown to receiver |
| `--https` | Use HTTPS (default: true) |
| `-w, --webrtc` | Send via WebRTC signaling server |
| `-t, --target` | Target peer ID (required for WebRTC) |
| `--preserve-structure` | Keep subdirectory structure (default: true) |
| `--config-dir` | Config directory for trusted devices |
| `--stun-servers` | Custom STUN servers for WebRTC |
| `--dapi` | Use Download API (reverse transfer) |

### scan command

| Flag | Description |
| ---- | ----------- |
| `-t, --timeout` | Scan duration in seconds (default: 4) |
| `-n, --lan` | Enable LAN discovery (mDNS/UDP) |
| `-l, --legacy` | Enable legacy HTTP subnet scan |
| `-w, --webrtc` | Enable WebRTC signaling discovery |
| `-j, --json` | Output results as JSON |
| `-e, --exclude-id-file` | File with signaling ID to exclude |
| `--devname` | Device name shown to other peers |

## Trusted Devices (PAIR)

LocalSend supports device pairing to skip PIN verification for trusted devices.

```bash
# Enable trusted devices with config directory
./localsend recv -d ~/Downloads --config-dir ~/.config/localsend

# Require pairing for all WebRTC transfers
./localsend recv -d ~/Downloads --config-dir ~/.config/localsend --require-pairing
```

When `--config-dir` is set:
- Paired devices are stored in `trusted_devices.json`
- Maximum 100 devices (oldest evicted when full)
- Trusted devices skip PIN verification automatically

## Custom STUN Servers

For corporate networks or privacy-conscious users:

```bash
./localsend recv -d ~/Downloads --stun-servers stun:stun.example.com:3478

./localsend send -w --target <id> --stun-servers stun:stun.example.com:3478 myfile.epub
```

Default: Google STUN servers (`stun:stun.l.google.com:19302`)

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
