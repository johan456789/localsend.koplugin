package recv

import (
	"context"
	"crypto/tls"
	"encoding/json"
	"fmt"
	"io/fs"
	"log/slog"
	"os"
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
	router            *ExtensionRouter // Routes files to different dirs by extension
	listenAddr        string           // Custom listen address (defaults to constants.DefaultListenAddr)

	// configMu protects configuration fields that can be modified after creation
	// (expectedPin, allowedExtensions, transferLogPath, router, listenAddr)
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
	fr.transferLogPath = path
}

func (fr *FileReceiver) LogTransfer(filename string, size int64, sender string) {
	fr.configMu.RLock()
	logPath := fr.transferLogPath
	fr.configMu.RUnlock()

	if logPath == "" {
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

	f, err := os.OpenFile(logPath, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0644)
	if err != nil {
		slog.Error("Failed to open transfer log", "error", err)
		return
	}
	defer func() { _ = f.Close() }()

	_, _ = f.Write(data)
	_, _ = f.WriteString("\n")
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
		slog.Info("Generating https certificate")

		// Get cert paths from the certs directory next to the binary
		privkeyFile, certFile, err := lsutils.GetCertPaths()
		if err != nil {
			return fmt.Errorf("failed to get certificate paths: %w", err)
		}
		fr.cert, err = lsutils.LoadOrGenTLScert(privkeyFile, certFile)
		if err != nil {
			return fmt.Errorf("failed to load or generate TLS certificate: %w", err)
		}

		// See https://github.com/localsend/protocol section. 2
		fr.identity.Fingerprint = utils.SHA256ofCert(fr.cert.Leaf)
	}

	// start advertisement
	fr.discoverier, err = localsend.NewDiscoverier(fr.identity, fr.supportHttps)
	if err != nil {
		return fmt.Errorf("failed to create discoverer: %w", err)
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

	go func() { _ = fr.advertise() }() // let others know we are here

	// Issue #25 fix: Listen for context cancellation to trigger graceful shutdown
	go func() {
		<-ctx.Done()
		_ = fr.Stop()
	}()

	return lsutils.ListenWithTLS(fr.webServer, fr.listenAddr, fr.cert, fr.supportHttps)
}

func (fr *FileReceiver) advertise() error {
	return fr.discoverier.Listen()
}

func (fr *FileReceiver) Stop() error {
	slog.Info("Stop receiving")

	fr.sessman.Stop()
	_ = fr.discoverier.Shutdown()

	// Graceful shutdown with 5 second timeout
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	return fr.webServer.ShutdownWithContext(ctx)
}
