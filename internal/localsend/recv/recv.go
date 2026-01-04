package recv

import (
	"context"
	"crypto/tls"
	"encoding/json"
	"fmt"
	"io/fs"
	"log/slog"
	"os"
	"os/exec"
	"sync"
	"time"

	"localsend-cli/internal/localsend"
	"localsend-cli/internal/localsend/constants"
	sess "localsend-cli/internal/localsend/session"
	lsutils "localsend-cli/internal/localsend/utils"
	"localsend-cli/internal/models"
	"localsend-cli/internal/utils"

	"github.com/gofiber/fiber/v2"
)

type FileReceiver struct {
	cert              tls.Certificate
	identity          models.DeviceInfo
	webServer         *fiber.App
	supportHttps      bool
	sessman           *sess.RecvSessManager
	saveToDir         string
	discoverier       *localsend.Discoverier
	expectedPin       string
	allowedExtensions []string         // New field for extension filtering
	transferLogPath   string           // Path to transfer log file
	transferLogFile   *os.File         // Persistent file handle for transfer log
	onTransferCmd     string           // Shell command to run after each transfer
	router            *ExtensionRouter // Routes files to different dirs by extension
	listenAddr        string           // Custom listen address (defaults to constants.DefaultListenAddr)

	// configMu protects configuration fields that can be modified after creation
	// (expectedPin, allowedExtensions, transferLogPath, transferLogFile, onTransferCmd, router, listenAddr)
	configMu sync.RWMutex

	// V3 nonce caches for token verification
	receivedNonceCache  *localsend.NonceCache // nonces received from clients
	generatedNonceCache *localsend.NonceCache // nonces generated for clients
}

// TransferLogEntry represents a single transfer log entry
type TransferLogEntry struct {
	Timestamp string `json:"timestamp"`
	Filename  string `json:"filename"`
	Size      int64  `json:"size"`
	Sender    string `json:"sender"`
}

func NewFileReceiver(devname string, saveToDir string, supportHttps bool) *FileReceiver {
	return &FileReceiver{
		identity:            models.NewDeviceInfo(devname, lsutils.GenFingerprint()),
		webServer:           lsutils.NewWebServer(),
		supportHttps:        supportHttps,
		saveToDir:           saveToDir,
		sessman:             sess.NewRecvSessManager(),
		allowedExtensions:   nil, // nil means accept all
		listenAddr:          constants.DefaultListenAddr,
		receivedNonceCache:  localsend.NewNonceCache(200),
		generatedNonceCache: localsend.NewNonceCache(200),
	}
}

func (fr *FileReceiver) SetPIN(pin string) {
	fr.configMu.Lock()
	defer fr.configMu.Unlock()
	fr.expectedPin = pin
}

// SetListenAddr sets a custom listen address (e.g., "127.0.0.1:0" for random port).
// Must be called before Start().
func (fr *FileReceiver) SetListenAddr(addr string) {
	fr.configMu.Lock()
	defer fr.configMu.Unlock()
	fr.listenAddr = addr
}

// ListenAddr returns the configured listen address.
func (fr *FileReceiver) ListenAddr() string {
	fr.configMu.RLock()
	defer fr.configMu.RUnlock()
	return fr.listenAddr
}

func (fr *FileReceiver) SetTransferLog(path string) {
	fr.configMu.Lock()
	defer fr.configMu.Unlock()

	// Close existing file handle if any
	if fr.transferLogFile != nil {
		_ = fr.transferLogFile.Close()
		fr.transferLogFile = nil
	}

	fr.transferLogPath = path

	// Open the new log file if path is provided
	if path != "" {
		f, err := os.OpenFile(path, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0644)
		if err != nil {
			slog.Error("Failed to open transfer log", "path", path, "error", err)
			return
		}
		fr.transferLogFile = f
	}
}

// closeTransferLog closes the transfer log file handle.
func (fr *FileReceiver) closeTransferLog() {
	fr.configMu.Lock()
	defer fr.configMu.Unlock()
	if fr.transferLogFile != nil {
		_ = fr.transferLogFile.Close()
		fr.transferLogFile = nil
	}
}

// SetOnTransferCmd sets a shell command to run after each file transfer.
// The command runs asynchronously to avoid blocking the transfer.
func (fr *FileReceiver) SetOnTransferCmd(cmd string) {
	fr.configMu.Lock()
	defer fr.configMu.Unlock()
	fr.onTransferCmd = cmd
}

func (fr *FileReceiver) LogTransfer(filename string, size int64, sender string) {
	fr.configMu.Lock()
	defer fr.configMu.Unlock()

	// Always run callback, even if logging is disabled
	cmd := fr.onTransferCmd
	if cmd != "" {
		go func() {
			if err := exec.Command("sh", "-c", cmd).Run(); err != nil {
				slog.Debug("on-transfer command failed", "cmd", cmd, "error", err)
			}
		}()
	}

	if fr.transferLogFile == nil {
		return
	}

	// Sanitize inputs to prevent log injection
	entry := TransferLogEntry{
		Timestamp: time.Now().Format(time.RFC3339),
		Filename:  utils.SanitizeForLog(filename),
		Size:      size,
		Sender:    utils.SanitizeForLog(sender),
	}

	data, err := json.Marshal(entry)
	if err != nil {
		slog.Error("Failed to marshal transfer log entry", "error", err)
		return
	}

	_, _ = fr.transferLogFile.Write(data)
	_, _ = fr.transferLogFile.WriteString("\n")
}

// SetAllowedExtensions sets the list of allowed file extensions.
// Extensions should be lowercase without the leading dot (e.g., "pdf", "epub").
// If empty or nil, all extensions are accepted.
func (fr *FileReceiver) SetAllowedExtensions(extensions []string) {
	fr.configMu.Lock()
	defer fr.configMu.Unlock()
	fr.allowedExtensions = extensions
	if len(extensions) > 0 {
		slog.Info("File extension filter enabled", "allowed", extensions)
	}
}

// SetExtensionRouter sets the router for extension-based directory routing.
func (fr *FileReceiver) SetExtensionRouter(router *ExtensionRouter) {
	fr.configMu.Lock()
	defer fr.configMu.Unlock()
	fr.router = router
}

// GetSaveDir returns the appropriate save directory for a file.
// Uses the router if configured, otherwise falls back to the default saveToDir.
func (fr *FileReceiver) GetSaveDir(filename string) string {
	fr.configMu.RLock()
	router := fr.router
	fr.configMu.RUnlock()

	if router != nil {
		return router.GetSaveDir(filename)
	}
	return fr.saveToDir
}

// IsExtensionAllowed checks if a filename has an allowed extension.
// Returns true if no filter is set or if the extension is in the allowed list.
func (fr *FileReceiver) IsExtensionAllowed(filename string) bool {
	fr.configMu.RLock()
	allowed := fr.allowedExtensions
	fr.configMu.RUnlock()
	return utils.IsExtensionAllowed(filename, allowed)
}

// getExpectedPIN returns the expected PIN in a thread-safe manner.
// Used by handlers to check PIN without races.
func (fr *FileReceiver) getExpectedPIN() string {
	fr.configMu.RLock()
	defer fr.configMu.RUnlock()
	return fr.expectedPin
}

// hasExtensionFilter returns true if an extension filter is configured.
// Used by handlers to check if filtering is needed.
func (fr *FileReceiver) hasExtensionFilter() bool {
	fr.configMu.RLock()
	defer fr.configMu.RUnlock()
	return len(fr.allowedExtensions) > 0
}

func (fr *FileReceiver) Init() error {
	var err error

	// ensure save directory exists
	err = os.MkdirAll(fr.saveToDir, fs.ModePerm)
	if err != nil {
		return fmt.Errorf("failed to create save directory: %w", err)
	}

	if fr.supportHttps {
		// Get cert paths from the certs directory next to the binary
		privkeyFile, certFile, err := lsutils.GetCertPaths()
		if err != nil {
			return fmt.Errorf("failed to get certificate paths: %w", err)
		}

		// Check if certs already exist
		_, keyErr := os.Stat(privkeyFile)
		_, certErr := os.Stat(certFile)
		if keyErr == nil && certErr == nil {
			slog.Info("Loading https certificate")
		} else {
			slog.Info("Generating https certificate")
		}

		fr.cert, err = lsutils.LoadOrGenTLScert(privkeyFile, certFile)
		if err != nil {
			return fmt.Errorf("failed to load or generate TLS certificate: %w", err)
		}

		// See https://github.com/localsend/protocol section. 2
		fr.identity.Fingerprint = utils.SHA256ofCert(fr.cert.Leaf)
	}

	// start advertisement (non-fatal if it fails - server can still work without discovery)
	fr.discoverier, err = localsend.NewDiscoverier(fr.identity, fr.supportHttps)
	if err != nil {
		slog.Warn("Failed to create discoverer (device won't be discoverable)", "error", err)
		// Continue without discovery - server can still accept connections by IP
	}

	// start session cleanup task
	fr.sessman.Start()

	return nil
}

func (fr *FileReceiver) Start(ctx context.Context) error {
	server := fr.webServer

	// V2 routes
	server.Post(constants.PreuploadPath, fr.preUploadHandler)
	server.Post(constants.UploadPath, fr.uploadHandler)
	server.Post(constants.CancelPath, fr.cancelHandler)
	server.Get(constants.InfoPath, fr.infoHandler)
	server.Get(constants.InfoPathV1, fr.infoHandler)
	server.Post(constants.RegisterPath, fr.registerHandler)
	server.Post(constants.RegisterPathV1, fr.registerHandler)

	// V3 routes
	server.Post(constants.NoncePathV3, fr.nonceExchangeHandler)
	server.Post(constants.RegisterPathV3, fr.registerV3Handler)
	server.Post(constants.PreuploadPathV3, fr.preUploadV3Handler)
	server.Post(constants.UploadPathV3, fr.uploadHandler) // Same logic as v2
	server.Post(constants.CancelPathV3, fr.cancelHandler) // Same logic as v2
	server.Get(constants.InfoPathV3, fr.infoV3Handler)

	slog.Info("Waiting for files (Ctrl-C to terminate)")

	// Start discovery/advertisement (with retry if network wasn't available at init)
	go fr.startDiscoveryWithRetry(ctx)

	// Listen for context cancellation to trigger graceful shutdown
	go func() {
		<-ctx.Done()
		_ = fr.Stop()
	}()

	return lsutils.ListenWithTLS(fr.webServer, fr.listenAddr, fr.cert, fr.supportHttps)
}

// startDiscoveryWithRetry starts the discovery/advertisement loop.
// If discoverer wasn't created at Init (no network), it retries every 5 seconds until success or context cancellation.
func (fr *FileReceiver) startDiscoveryWithRetry(ctx context.Context) {
	// If discoverer already exists, just start it
	if fr.discoverier != nil {
		_ = fr.discoverier.Listen()
		return
	}

	// Discoverer doesn't exist - retry creating it periodically
	ticker := time.NewTicker(5 * time.Second)
	defer ticker.Stop()

	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			var err error
			fr.discoverier, err = localsend.NewDiscoverier(fr.identity, fr.supportHttps)
			if err != nil {
				// Still no network, keep trying
				continue
			}
			slog.Info("Discovery started (network became available)")
			// Success - start the listen loop (blocks until shutdown)
			_ = fr.discoverier.Listen()
			return
		}
	}
}

func (fr *FileReceiver) advertise() error {
	if fr.discoverier == nil {
		return nil // Discovery not available
	}
	return fr.discoverier.Listen()
}

func (fr *FileReceiver) Stop() error {
	slog.Info("Stop receiving")

	fr.sessman.Stop()
	if fr.discoverier != nil {
		_ = fr.discoverier.Shutdown()
	}
	fr.closeTransferLog()

	// Graceful shutdown with 5 second timeout
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	return fr.webServer.ShutdownWithContext(ctx)
}
