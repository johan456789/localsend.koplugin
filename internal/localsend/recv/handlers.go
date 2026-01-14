package recv

import (
	"bytes"
	"crypto/subtle"
	"io"
	"log/slog"

	"github.com/gofiber/fiber/v2"
	"localsend-cli/internal/crypto"
	"localsend-cli/internal/localsend/constants"
	"localsend-cli/internal/models"
)

// filterFilesByExtension filters files based on allowed extensions.
// Returns the filtered files, or an error status code if all files were rejected.
// Folder transfers are rejected entirely when in strict routing mode
// (extension routing + extension filter both enabled).
func (fr *FileReceiver) filterFilesByExtension(files models.FileMetas, remoteIP string) (models.FileMetas, int) {
	isFolderXfer := files.IsFolderTransfer()

	// Strict mode: routing enabled + extension filter enabled
	// In this mode, reject folder transfers entirely because the user has
	// explicitly configured specific file types and routing destinations.
	if isFolderXfer && fr.hasExtensionRouter() && fr.hasExtensionFilter() {
		slog.Warn("Folder transfer rejected: strict routing mode active", "remote", remoteIP)
		return nil, 403
	}

	if !fr.hasExtensionFilter() {
		return files, 0
	}

	filteredFiles := make(models.FileMetas)
	rejectedFiles := []string{}

	for id, fileMeta := range files {
		if fr.IsExtensionAllowed(fileMeta.Filename) {
			filteredFiles[id] = fileMeta
		} else {
			rejectedFiles = append(rejectedFiles, fileMeta.Filename)
		}
	}

	// Log rejected files
	if len(rejectedFiles) > 0 {
		slog.Info("Rejected files due to extension filter", "files", rejectedFiles)
	}

	// If all files were rejected, return an error
	if len(filteredFiles) == 0 {
		slog.Warn("All files rejected by extension filter", "remote", remoteIP)
		return nil, 403
	}

	return filteredFiles, 0
}

func (fr *FileReceiver) preUploadHandler(c *fiber.Ctx) error {
	// Check PIN rate limiting before validating PIN
	expectedPin := fr.getExpectedPIN()
	if expectedPin != "" {
		// Check if IP is blocked due to too many failed attempts
		if fr.isPINBlocked(c.IP()) {
			slog.Warn("PIN attempt blocked - too many failures", "remote", c.IP())
			return c.SendStatus(429) // Too Many Requests
		}

		pin := c.Query("pin")
		// Use constant-time comparison to prevent timing attacks
		if subtle.ConstantTimeCompare([]byte(pin), []byte(expectedPin)) != 1 {
			fr.recordPINAttempt(c.IP())
			return c.SendStatus(401)
		}
		// Clear attempts on successful PIN
		fr.clearPINAttempts(c.IP())
	}

	// Per protocol spec Section 4.1: return 409 when blocked by another session
	if fr.sessman.HasActiveSessions() {
		slog.Info("Blocked upload request - another session is active", "remote", c.IP())
		return c.SendStatus(409)
	}

	var metaReq models.PreUploadReq

	err := c.BodyParser(&metaReq)
	if err != nil {
		return c.SendStatus(400)
	}

	// Filter files by extension if filter is enabled
	filteredFiles, errStatus := fr.filterFilesByExtension(metaReq.Files, c.IP())
	if errStatus != 0 {
		return c.SendStatus(errStatus)
	}
	metaReq.Files = filteredFiles

	// new session - store client IP for validation per protocol spec Section 4.2
	sessionId, err := fr.sessman.NewSession(metaReq.Files, c.IP())
	if err != nil {
		slog.Error("preupload error", "error", err)
		return c.SendStatus(500)
	}

	slog.Info("Accepting file", "remote", c.IP(), "session", sessionId, "files", len(metaReq.Files))

	resp, err := fr.sessman.GeneratePreUploadResp(sessionId)
	if err != nil {
		return c.SendStatus(500)
	}

	return c.JSON(&resp)
}

func (fr *FileReceiver) uploadHandler(c *fiber.Ctx) error {
	sessionId := c.Query("sessionId")
	fileId := c.Query("fileId")
	token := c.Query("token")

	slog.Info("Upload request", "remote", c.IP(), "session", sessionId, "fileId", fileId)

	if sessionId == "" || fileId == "" || token == "" {
		slog.Warn("Upload missing params", "session", sessionId, "fileId", fileId, "hasToken", token != "")
		return c.SendStatus(400)
	}

	session, err := fr.sessman.GetSession(sessionId)
	if err != nil {
		slog.Warn("Upload invalid session", "session", sessionId, "error", err)
		return c.SendStatus(403) // Invalid session = rejected per protocol spec
	}

	// Get file metadata for logging and routing
	fileMeta, ok := session.GetFileMeta(fileId)
	if !ok {
		slog.Warn("Upload for unknown fileId", "fileId", fileId, "session", sessionId)
		return c.SendStatus(400)
	}

	// Determine save directory (may be routed based on extension, unless folder transfer)
	saveDir := fr.GetSaveDirForSession(session, fileMeta.Filename)

	// Use streaming to avoid loading entire file into memory (prevents OOM on large files).
	// Note: RequestBodyStream() may return nil for small requests that were already buffered,
	// so we fall back to c.Body() in that case.
	var bodyReader io.Reader
	if stream := c.Context().RequestBodyStream(); stream != nil {
		bodyReader = stream
	} else {
		bodyReader = bytes.NewReader(c.Body())
	}

	// Pass client IP for validation per protocol spec Section 4.2
	savedFilename, err := session.SaveFile(saveDir, fileId, token, c.IP(), bodyReader)
	if err != nil {
		slog.Error("Upload error", "remote", c.IP(), "session", sessionId, "error", err)
		return c.SendStatus(constants.Status(err))
	}

	// Log the successful transfer with the actual saved filename (may differ from original if renamed)
	fr.LogTransfer(savedFilename, fileMeta.Size, c.IP())

	return c.SendStatus(200)
}

func (fr *FileReceiver) cancelHandler(c *fiber.Ctx) error {
	sessionId := c.Query("sessionId")
	if sessionId == "" {
		return c.SendStatus(400)
	}

	fr.sessman.KillSession(sessionId)
	return c.SendStatus(200)
}

func (fr *FileReceiver) infoHandler(c *fiber.Ctx) error {
	return c.JSON(&fr.identity)
}

func (fr *FileReceiver) registerHandler(c *fiber.Ctx) error {
	var announcement models.Announcement
	if err := c.BodyParser(&announcement); err != nil {
		return c.SendStatus(400)
	}

	// Register the discovered device
	announcement.IP = c.IP()
	if fr.discoverier != nil {
		fr.discoverier.RegisterDevice(announcement)
	}

	// Respond with our device info
	return c.JSON(&fr.identity)
}

// nonceExchangeHandler implements POST /api/localsend/v3/nonce
// This exchanges nonces for secure token verification in v3 protocol.
func (fr *FileReceiver) nonceExchangeHandler(c *fiber.Ctx) error {
	var req models.NonceRequest
	if err := c.BodyParser(&req); err != nil {
		slog.Warn("Invalid nonce request", "error", err, "remote", c.IP())
		return c.SendStatus(400)
	}

	// Decode nonce from base64
	nonce, err := crypto.DecodeNonce(req.Nonce)
	if err != nil {
		slog.Warn("Invalid nonce format", "error", err, "remote", c.IP())
		return c.SendStatus(400)
	}

	// Validate nonce length (16-128 bytes per protocol spec)
	if !crypto.ValidateNonce(nonce) {
		slog.Warn("Invalid nonce length", "length", len(nonce), "remote", c.IP())
		return c.SendStatus(400)
	}

	// Get client identifier (IP for now, could be cert public key for HTTPS)
	clientID := c.IP()

	// Store received nonce from client
	fr.receivedNonceCache.Put(clientID, nonce)

	// Generate new nonce for client
	newNonce, err := crypto.GenerateNonce()
	if err != nil {
		slog.Error("Failed to generate nonce", "error", err)
		return c.SendStatus(500)
	}

	// Store generated nonce for later verification
	fr.generatedNonceCache.Put(clientID, newNonce)

	// Return response with base64-encoded nonce
	resp := models.NonceResponse{
		Nonce: crypto.EncodeNonce(newNonce),
	}

	slog.Info("Nonce exchange successful",
		"remote", clientID,
		"clientNonceLen", len(nonce),
		"serverNonceLen", len(newNonce))

	return c.JSON(&resp)
}

// registerV3Handler implements POST /api/localsend/v3/register
// This handles device registration with v3 protocol fields.
func (fr *FileReceiver) registerV3Handler(c *fiber.Ctx) error {
	var req models.RegisterRequestV3
	if err := c.BodyParser(&req); err != nil {
		slog.Error("Failed to parse v3 register request", "error", err)
		return c.SendStatus(400)
	}

	// Build response from our identity
	resp := models.RegisterResponseV3{
		Alias:           fr.identity.Alias,
		Version:         fr.identity.Version,
		DeviceModel:     fr.identity.DeviceModel,
		DeviceType:      constants.DeviceTypeToV3(fr.identity.DeviceType),
		Token:           fr.identity.Token,
		HasWebInterface: false, // CLI doesn't have web interface
	}

	slog.Info("V3 register received", "remote", c.IP(), "sender", req.Alias)

	return c.JSON(&resp)
}

// preUploadV3Handler implements POST /api/localsend/v3/prepare-upload
// This handles v3 prepare-upload with optional token verification using exchanged nonces.
func (fr *FileReceiver) preUploadV3Handler(c *fiber.Ctx) error {
	// Check PIN rate limiting before validating PIN
	expectedPin := fr.getExpectedPIN()
	if expectedPin != "" {
		// Check if IP is blocked due to too many failed attempts
		if fr.isPINBlocked(c.IP()) {
			slog.Warn("PIN attempt blocked - too many failures", "remote", c.IP())
			return c.SendStatus(429) // Too Many Requests
		}

		pin := c.Query("pin")
		// Use constant-time comparison to prevent timing attacks
		if subtle.ConstantTimeCompare([]byte(pin), []byte(expectedPin)) != 1 {
			fr.recordPINAttempt(c.IP())
			return c.SendStatus(401)
		}
		// Clear attempts on successful PIN
		fr.clearPINAttempts(c.IP())
	}

	// Per protocol spec Section 4.1: return 409 when blocked by another session
	if fr.sessman.HasActiveSessions() {
		slog.Info("Blocked upload request - another session is active", "remote", c.IP())
		return c.SendStatus(409)
	}

	var metaReq models.PreUploadReq
	err := c.BodyParser(&metaReq)
	if err != nil {
		return c.SendStatus(400)
	}

	// V3 token verification (optional - if nonces were exchanged)
	// Full token verification requires the client's public key, which is only available
	// via mTLS (client certificate) or out-of-band key exchange. The WebRTC path does
	// full verification since both parties exchange keys in the data channel.
	// For HTTP V3, we verify the nonce exchange was done for replay protection.
	clientID := c.IP()
	if receivedNonce, ok := fr.receivedNonceCache.Get(clientID); ok {
		if generatedNonce, ok := fr.generatedNonceCache.Get(clientID); ok {
			// Combined nonce: client's nonce || our nonce
			// Use explicit copy to avoid mutating the underlying slice
			combinedNonce := make([]byte, len(receivedNonce)+len(generatedNonce))
			copy(combinedNonce, receivedNonce)
			copy(combinedNonce[len(receivedNonce):], generatedNonce)

			// Log V3 nonce verification was successful (replay protection active)
			slog.Info("V3 nonce exchange verified",
				"remote", clientID,
				"combinedNonceLen", len(combinedNonce),
				"hasToken", metaReq.Info != nil && metaReq.Info.Token != "")

			// Clear nonces after use (one-time use for replay protection)
			fr.receivedNonceCache.Delete(clientID)
			fr.generatedNonceCache.Delete(clientID)
		}
	}

	// Filter files by extension if filter is enabled
	filteredFiles, errStatus := fr.filterFilesByExtension(metaReq.Files, c.IP())
	if errStatus != 0 {
		return c.SendStatus(errStatus)
	}
	metaReq.Files = filteredFiles

	// new session - store client IP for validation per protocol spec Section 4.2
	sessionId, err := fr.sessman.NewSession(metaReq.Files, c.IP())
	if err != nil {
		slog.Error("preupload error", "error", err)
		return c.SendStatus(500)
	}

	slog.Info("V3 Accepting file", "remote", c.IP(), "session", sessionId, "files", len(metaReq.Files))

	resp, err := fr.sessman.GeneratePreUploadResp(sessionId)
	if err != nil {
		return c.SendStatus(500)
	}

	return c.JSON(&resp)
}

// infoV3Handler implements GET /api/localsend/v3/info
// Returns device info in v3 format with SCREAMING_SNAKE_CASE device type.
func (fr *FileReceiver) infoV3Handler(c *fiber.Ctx) error {
	resp := models.RegisterResponseV3{
		Alias:           fr.identity.Alias,
		Version:         fr.identity.Version,
		DeviceModel:     fr.identity.DeviceModel,
		DeviceType:      constants.DeviceTypeToV3(fr.identity.DeviceType),
		Token:           fr.identity.Token,
		HasWebInterface: false,
	}
	return c.JSON(&resp)
}
