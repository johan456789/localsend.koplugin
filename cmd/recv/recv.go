package recv

import (
	"context"
	"encoding/json"
	"log/slog"
	"os"
	"sync"
	"time"

	"github.com/spf13/cobra"
	"localsend-cli/internal/crypto"
	lsrecv "localsend-cli/internal/localsend/recv"
	lsutils "localsend-cli/internal/localsend/utils"
	"localsend-cli/internal/storage"
	"localsend-cli/internal/utils"
	"localsend-cli/internal/webrtc/signaling"
	"localsend-cli/internal/webrtc/transfer"
)

var (
	devname        string
	savetodir      string
	supportHttps   bool
	pin            string
	acceptExt      string
	logFile        string
	webrtcMode     bool
	extRouting     string
	onTransferCmd  string
	configDir      string
	requirePairing bool
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
		recver.SetOnTransferCmd(onTransferCmd)

		// Set extension router if configured
		if router != nil {
			recver.SetExtensionRouter(router)
		}

		// Set allowed extensions if provided
		allowedExts := utils.ParseExtensionList(acceptExt)
		if len(allowedExts) > 0 {
			recver.SetAllowedExtensions(allowedExts)
		}

		if err := recver.Init(); err != nil {
			slog.Error("Failed to initialize receiver", "error", err)
			return
		}

		// Create a context that will be cancelled on shutdown signal
		ctx, cancel := context.WithCancel(context.Background())

		// Start HTTP server (will shut down when context is cancelled)
		wg.Add(1)
		go func() {
			defer wg.Done()
			err := recver.Start(ctx)
			if err != nil {
				slog.Error("Fail to start server", "error", err)
				return
			}
		}()

		if webrtcMode {
			wg.Add(1)
			go func() {
				defer wg.Done()
				startWebRTCReceiver(ctx, devname, savetodir, pin, allowedExts, extRoutes, recver.LogTransfer, configDir, requirePairing)
			}()
		}

		<-utils.WaitForSignal()
		cancel() // Signal both HTTP and WebRTC receivers to stop

		// Wait for goroutines with timeout to prevent hanging on shutdown
		done := make(chan struct{})
		go func() {
			wg.Wait()
			close(done)
		}()

		select {
		case <-done:
			// Clean shutdown
		case <-time.After(5 * time.Second):
			slog.Warn("Shutdown timeout: some goroutines did not exit cleanly")
		}
	},
}

func startWebRTCReceiver(ctx context.Context, deviceName, saveDir, pin string, allowedExts []string, extRoutes map[string]string, logTransfer func(filename string, size int64, sender string), cfgDir string, reqPairing bool) {
	// Generate signing key and token
	key, token, err := crypto.GenerateKeyPairWithToken()
	if err != nil {
		slog.Error("Failed to generate key pair with token", "error", err)
		return
	}

	// Initialize trusted device store if config dir is provided
	var trustedStore *storage.TrustedDeviceStore
	if cfgDir != "" {
		trustedStore, err = storage.NewTrustedDeviceStore(cfgDir)
		if err != nil {
			slog.Error("Failed to initialize trusted device store", "error", err)
			// Continue without trust - just won't persist
		} else {
			slog.Info("Trusted device store initialized", "config", cfgDir)
		}
	}

	// Connect to signaling server
	info := signaling.NewClientInfo(deviceName, token)

	client, err := signaling.Connect(signaling.DefaultSignalingServer, info)
	if err != nil {
		slog.Error("Failed to connect to signaling server", "error", err)
		return
	}
	defer func() { _ = client.Close() }()

	// Set up token refresh for long-running sessions (matches web client behavior)
	// Tokens are valid for 1 hour; refresh every 30 minutes to maintain validity
	client.SetTokenGenerator(func() (string, error) {
		return key.GenerateTokenTimestamp()
	})

	slog.Info("WebRTC receiver listening", "id", client.ClientID())

	// Create receiver
	receiver := transfer.NewRTCReceiver(client, key, pin, saveDir)
	defer func() { _ = receiver.Close() }()

	// Set trusted device store if configured
	if trustedStore != nil {
		receiver.SetTrustedStore(trustedStore)
	}

	// Set pairing requirement
	if reqPairing {
		receiver.SetRequirePairing(true)
		slog.Info("Pairing required for WebRTC transfers")
	}

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
			// Check extension filter using shared utility
			if !utils.IsExtensionAllowed(f.FileName, allowedExts) {
				slog.Info("Rejecting file (extension not allowed)", "name", f.FileName)
				continue
			}
			slog.Info("Accepting file via WebRTC", "name", f.FileName, "size", f.Size)
			ids = append(ids, f.ID)
		}
		return ids
	})

	// Listen for offers with context for proper cancellation
	receiver.ListenForOffersWithContext(ctx, func(offer signaling.WsServerMessage) {
		slog.Info("Received WebRTC offer", "peer", offer.Peer.Alias)
		// Set sender info for PAIR flow (used for persisting trusted devices)
		receiver.SetSenderInfo(offer.Peer.Alias)
		if err := receiver.AcceptOffer(offer); err != nil {
			slog.Error("Failed to accept offer", "error", err)
		}
	})

	// Block until context is cancelled (shutdown signal from main)
	<-ctx.Done()
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
	Cmd.PersistentFlags().StringVar(&onTransferCmd, "on-transfer", "", "Shell command to run after each file transfer completes (e.g., 'touch /tmp/notify')")
	Cmd.PersistentFlags().StringVar(&configDir, "config-dir", "", "Config directory for trusted devices persistence")
	Cmd.PersistentFlags().BoolVar(&requirePairing, "require-pairing", false, "Require PAIR before accepting WebRTC transfers from unknown devices")
}
