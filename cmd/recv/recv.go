package recv

import (
	"encoding/json"
	"log/slog"
	"os"
	"path/filepath"
	"strings"
	"sync"

	"localsend-cli/internal/crypto"
	lsrecv "localsend-cli/internal/localsend/recv"
	lsutils "localsend-cli/internal/localsend/utils"
	"localsend-cli/internal/utils"
	"localsend-cli/internal/webrtc/signaling"
	"localsend-cli/internal/webrtc/transfer"
	"github.com/spf13/cobra"
)

var (
	devname      string
	savetodir    string
	supportHttps bool
	pin          string
	acceptExt    string
	logFile      string
	webrtcMode   bool
	extRouting   string
)

var Cmd = &cobra.Command{
	Use:   "recv",
	Short: "Receive files from localsend instance",
	Long:  "Receive files from localsend instance",
	Run: func(cmd *cobra.Command, args []string) {
		var wg sync.WaitGroup

		// Load extension routing config if provided
		var router *lsrecv.ExtensionRouter
		var extRoutes map[string]string
		if extRouting != "" {
			router = lsrecv.NewExtensionRouter(savetodir)
			if err := router.LoadFromFile(extRouting); err != nil {
				slog.Error("Failed to load extension routing config", "error", err)
				return
			}
			if err := router.EnsureDirectories(); err != nil {
				slog.Warn("Failed to create some routing directories", "error", err)
			}
			slog.Info("Extension routing enabled", "config", extRouting)

			// Also extract routes for WebRTC receiver
			extRoutes = make(map[string]string)
			// Re-read the config to get the raw routes
			if data, err := os.ReadFile(extRouting); err == nil {
				_ = json.Unmarshal(data, &extRoutes)
			}
		}

		// HTTP receiver (always start unless webrtc-only)
		recver := lsrecv.NewFileReceiver(devname, savetodir, supportHttps)
		recver.SetPIN(pin)
		recver.SetTransferLog(logFile)

		// Set extension router if configured
		if router != nil {
			recver.SetExtensionRouter(router)
		}

		// Set allowed extensions if provided
		if acceptExt != "" {
			extensions := strings.Split(acceptExt, ",")
			for i, ext := range extensions {
				extensions[i] = strings.TrimSpace(strings.ToLower(ext))
			}
			recver.SetAllowedExtensions(extensions)
		}

		if err := recver.Init(); err != nil {
			slog.Error("Failed to initialize receiver", "error", err)
			return
		}

		// Start HTTP server
		wg.Add(1)
		go func() {
			defer wg.Done()
			err := recver.Start()
			if err != nil {
				slog.Error("Fail to start server", "error", err)
				return
			}
		}()

		// WebRTC receiver (enabled by default as v3 is the future)
		// Parse extensions for WebRTC receiver too
		var allowedExts []string
		if acceptExt != "" {
			allowedExts = strings.Split(acceptExt, ",")
			for i, ext := range allowedExts {
				allowedExts[i] = strings.TrimSpace(strings.ToLower(ext))
			}
		}

		if webrtcMode {
			wg.Add(1)
			go func() {
				defer wg.Done()
				startWebRTCReceiver(devname, savetodir, pin, allowedExts, extRoutes, recver.LogTransfer)
			}()
		}

		<-utils.WaitForSignal()

		_ = recver.Stop()
		wg.Wait()
	},
}

func startWebRTCReceiver(deviceName, saveDir, pin string, allowedExts []string, extRoutes map[string]string, logTransfer func(filename string, size int64, sender string)) {
	// Generate signing key for token
	key, err := crypto.GenerateKeyPair()
	if err != nil {
		slog.Error("Failed to generate key pair", "error", err)
		return
	}

	// Generate token
	token, err := key.GenerateTokenTimestamp()
	if err != nil {
		slog.Error("Failed to generate token", "error", err)
		return
	}

	// Connect to signaling server
	info := signaling.ClientInfoWithoutID{
		Alias:       deviceName,
		Version:     "2.1",
		DeviceModel: "LocalSend-CLI",
		DeviceType:  "headless",
		Token:       token,
	}

	client, err := signaling.Connect(signaling.DefaultSignalingServer, info)
	if err != nil {
		slog.Error("Failed to connect to signaling server", "error", err)
		return
	}
	defer func() { _ = client.Close() }()

	slog.Info("WebRTC receiver listening", "id", client.ClientID())

	// Create receiver
	receiver := transfer.NewRTCReceiver(client, key, pin, saveDir)
	defer func() { _ = receiver.Close() }()

	// Set extension routing if configured
	if len(extRoutes) > 0 {
		receiver.SetExtensionRoutes(extRoutes)
	}

	// Set up file received handler for transfer logging
	if logTransfer != nil {
		receiver.OnFileReceived(logTransfer)
	}

	// Set up file selection handler with extension filtering
	receiver.OnSelectFiles(func(files []transfer.RTCFileDto) []string {
		var ids []string
		for _, f := range files {
			// Check extension filter
			if len(allowedExts) > 0 {
				ext := filepath.Ext(f.FileName)
				if ext == "" {
					slog.Info("Rejecting file (no extension)", "name", f.FileName)
					continue
				}
				ext = strings.ToLower(ext[1:]) // Remove leading dot
				allowed := false
				for _, a := range allowedExts {
					if ext == a {
						allowed = true
						break
					}
				}
				if !allowed {
					slog.Info("Rejecting file (extension not allowed)", "name", f.FileName, "ext", ext)
					continue
				}
			}
			slog.Info("Accepting file via WebRTC", "name", f.FileName, "size", f.Size)
			ids = append(ids, f.ID)
		}
		return ids
	})

	// Listen for offers
	receiver.ListenForOffers(func(offer signaling.WsServerMessage) {
		slog.Info("Received WebRTC offer", "peer", offer.Peer.Alias)
		if err := receiver.AcceptOffer(offer); err != nil {
			slog.Error("Failed to accept offer", "error", err)
		}
	})

	// Block until signal
	<-utils.WaitForSignal()
}

func init() {
	Cmd.PersistentFlags().StringVarP(&devname, "devname", "n", lsutils.GenAlias(), "Device name that is advertising")
	Cmd.PersistentFlags().StringVarP(&savetodir, "dir", "d", ".", "Directory for received files")
	Cmd.PersistentFlags().StringVarP(&pin, "pin", "p", "", "PIN code")
	Cmd.PersistentFlags().BoolVar(&supportHttps, "https", true, "Do https")
	Cmd.PersistentFlags().StringVarP(&acceptExt, "accept-ext", "a", "", "Comma-separated list of allowed file extensions (e.g., epub,pdf,mobi). Empty means accept all.")
	Cmd.PersistentFlags().StringVarP(&logFile, "log", "l", "", "Path to transfer log file (JSON lines format)")
	Cmd.PersistentFlags().BoolVarP(&webrtcMode, "webrtc", "w", true, "Listen for WebRTC offers via signaling server (v3 protocol)")
	Cmd.PersistentFlags().StringVar(&extRouting, "ext-routing", "", "Path to extension routing config (JSON). Routes files to different directories by extension.")
}
