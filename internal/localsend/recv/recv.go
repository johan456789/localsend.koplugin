package recv

import (
	"context"
	"crypto/tls"
	"encoding/json"
	"fmt"
	"io/fs"
	"log/slog"
	"os"
	"path/filepath"
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
	allowedExtensions []string          // New field for extension filtering
	transferLogPath   string            // Path to transfer log file
	router            *ExtensionRouter  // Routes files to different dirs by extension

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
		receivedNonceCache:  localsend.NewNonceCache(200),
		generatedNonceCache: localsend.NewNonceCache(200),
	}
}

func (fr *FileReceiver) SetPIN(pin string) {
	fr.expectedPin = pin
}

func (fr *FileReceiver) SetTransferLog(path string) {
	fr.transferLogPath = path
}

func (fr *FileReceiver) LogTransfer(filename string, size int64, sender string) {
	if fr.transferLogPath == "" {
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

	f, err := os.OpenFile(fr.transferLogPath, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0644)
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
	fr.allowedExtensions = extensions
	if len(extensions) > 0 {
		slog.Info("File extension filter enabled", "allowed", extensions)
	}
}

// SetExtensionRouter sets the router for extension-based directory routing.
func (fr *FileReceiver) SetExtensionRouter(router *ExtensionRouter) {
	fr.router = router
}

// GetSaveDir returns the appropriate save directory for a file.
// Uses the router if configured, otherwise falls back to the default saveToDir.
func (fr *FileReceiver) GetSaveDir(filename string) string {
	if fr.router != nil {
		return fr.router.GetSaveDir(filename)
	}
	return fr.saveToDir
}

// IsExtensionAllowed checks if a filename has an allowed extension.
// Returns true if no filter is set or if the extension is in the allowed list.
func (fr *FileReceiver) IsExtensionAllowed(filename string) bool {
	return utils.IsExtensionAllowed(filename, fr.allowedExtensions)
}

// FilterFilesByExtension filters a file list, returning only files with allowed extensions.
// If allowedExtensions is empty, returns all files unchanged.
// Returns filtered files and a list of rejected filenames for logging.
func FilterFilesByExtension(files models.FileMetas, allowedExtensions []string) (filtered models.FileMetas, rejected []string) {
	if len(allowedExtensions) == 0 {
		return files, nil
	}

	filtered = make(models.FileMetas)
	for id, fileMeta := range files {
		if utils.IsExtensionAllowed(fileMeta.Filename, allowedExtensions) {
			filtered[id] = fileMeta
		} else {
			rejected = append(rejected, fileMeta.Filename)
		}
	}
	return filtered, rejected
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

		// load cert for https server
		// TODO: save certificate in user config directory
		privkeyFile := filepath.Join(os.TempDir(), "server.key.pem")
		certFile := filepath.Join(os.TempDir(), "server.crt")
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

func (fr *FileReceiver) Start() error {
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

	return lsutils.ListenWithTLS(fr.webServer, constants.DefaultListenAddr, fr.cert, fr.supportHttps)
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
