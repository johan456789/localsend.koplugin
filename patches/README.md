# LocalSend Text Input Patch for KOReader

A KOReader user patch that enables using LocalSend as an Input Method (IME) for your Kindle or e-reader. Type on your phone, receive text directly into KOReader text input fields.

## Features

- **Auto-start**: LocalSend server automatically starts when you tap on a text input field
- **Direct text insertion**: Received `.txt` files are inserted directly into the active text field
- **Clipboard fallback**: If direct insertion fails, text is copied to clipboard
- **Toast notifications**: Visual feedback for all actions
- **Auto-cleanup**: Received files are deleted after processing (no storage clutter)

## Requirements

- KOReader installed on your device
- [localsend.koplugin](https://github.com/johan456789/localsend.koplugin) installed
- LocalSend app on your phone ([Android](https://play.google.com/store/apps/details?id=org.localsend.localsend_app) / [iOS](https://apps.apple.com/app/localsend/id1661733229))

## Installation

1. **Ensure localsend.koplugin is installed**
   
   Follow the installation instructions at: https://github.com/johan456789/localsend.koplugin

2. **Copy the patch file**
   
   Copy `2-localsend-text-input.lua` to your KOReader patches directory:
   
   - **Kindle**: `koreader/patches/`
   - **Kobo**: `koreader/patches/`
   - **Desktop/Other**: `~/.config/koreader/patches/`

3. **Create the patches directory if needed**
   
   If the `patches` folder doesn't exist, create it:
   ```
   mkdir -p koreader/patches
   ```

4. **Restart KOReader**
   
   Fully close and reopen KOReader for the patch to take effect.

## Usage

1. **Open a text input field in KOReader**
   
   Examples:
   - Search (magnifying glass icon)
   - Add a note
   - Any dialog with text input

2. **You'll see a notification**: "LocalSend ready for text input"

3. **On your phone:**
   - Open LocalSend
   - Find your Kindle/e-reader (appears as "KOReader-TextInput")
   - Either:
     - Create a `.txt` file with your text and send it
     - Use "Send text" feature (will be sent as a `.txt` file)

4. **The text appears in your KOReader text field!**
   
   You'll see a notification confirming the action:
   - "Text inserted from LocalSend" - if directly inserted
   - "Text copied to clipboard from LocalSend" - if copied to clipboard (use long-press paste)

## How it Works

This patch:

1. Hooks into KOReader's `InputText` and `InputDialog` widgets
2. When a text input becomes active, starts a dedicated LocalSend server
3. The server only accepts `.txt` files and saves them to `/tmp/localsend_textinput/`
4. A poll task checks for new files every second
5. When a `.txt` file arrives:
   - Reads the content
   - Inserts it into the active text field (or copies to clipboard)
   - Deletes the file
   - Shows a toast notification
6. When the text input closes, the server stops

## Troubleshooting

### "LocalSend not found on my phone"

- Make sure both devices are on the same WiFi network
- Check that the main LocalSend server in KOReader isn't already running
- Try restarting both KOReader and LocalSend on your phone

### "Text not being inserted"

- The text will be appended to any existing text in the field
- If direct insertion fails, check if the text was copied to clipboard
- Try long-pressing in the text field and selecting "Paste"

### "Server doesn't start"

- Verify localsend.koplugin is properly installed
- Check that the `localsend` binary exists in the plugin folder
- Review KOReader's log for any error messages

### Viewing logs

On your device, check:
- Kindle: `koreader/crash.log` or enable debug logging

## Limitations

- Only `.txt` files are accepted (for security and simplicity)
- One text input session at a time
- Requires WiFi connection between devices
- Phone must manually send text each time (no persistent connection)

## Uninstall

Simply delete the patch file:
```
rm koreader/patches/2-localsend-text-input.lua
```

Then restart KOReader.

## License

Same as KOReader and localsend.koplugin (AGPL-3.0).
