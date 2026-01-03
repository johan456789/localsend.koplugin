package transfer

import (
	"context"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"hash"
	"log/slog"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"localsend-cli/internal/crypto"
	"localsend-cli/internal/localsend/session"
	"localsend-cli/internal/webrtc/signaling"
)

// Receiver handshake states
const (
	stateWaitNonce = iota
	stateWaitToken
	stateWaitPin
	stateWaitFileList
	stateWaitPairResponse // Waiting for sender's PAIR response
	stateWaitFiles
	stateReceivingFiles
)

// Configuration constants (Issue #22: extracted from magic numbers)
const (
	maxPINAttempts     = 3  // Maximum incorrect PIN attempts before closing connection
	tokenPreviewLength = 30 // Max characters to show in token preview logs
)

// RTCReceiver handles receiving files over WebRTC.
type RTCReceiver struct {
	signaling   *signaling.SignalingClient
	signingKey  *crypto.SigningKey
	peer        *PeerConnection
	pin         string
	pinAttempts int
	saveDir     string
	mu          sync.Mutex

	// Extension routing
	extRoutes map[string]string // lowercase ext -> directory

	// Handshake state
	state       int
	remoteNonce []byte
	localNonce  []byte
	finalNonce  []byte

	// Token verification (optional, requires PAIR flow for public key)
	senderPublicKey    crypto.VerifyingKey // Set via PAIR flow
	strictVerification bool                // If true, fail on invalid tokens
	requirePairing     bool                // If true, require PAIR before accepting files
	pendingFiles       []RTCFileDto        // Files pending while waiting for PAIR response

	// Files
	files       []RTCFileDto
	fileTokens  map[string]string // fileId -> token
	acceptedIDs []string

	// File writers
	currentFileID string
	fileWriters   map[string]*os.File
	filePaths     map[string]string // fileId -> actual saved path
	fileHashers   map[string]hash.Hash

	// Callbacks
	onSelectFiles  func([]RTCFileDto) []string
	onFileReceived func(filename string, size int64, sender string)
}

// NewRTCReceiver creates a new WebRTC receiver.
func NewRTCReceiver(sig *signaling.SignalingClient, key *crypto.SigningKey, pin, saveDir string) *RTCReceiver {
	return &RTCReceiver{
		signaling:   sig,
		signingKey:  key,
		pin:         pin,
		saveDir:     saveDir,
		state:       stateWaitNonce,
		fileTokens:  make(map[string]string),
		fileWriters: make(map[string]*os.File),
		filePaths:   make(map[string]string),
		fileHashers: make(map[string]hash.Hash),
	}
}

// OnSelectFiles sets the callback for selecting which files to accept.
func (r *RTCReceiver) OnSelectFiles(handler func([]RTCFileDto) []string) {
	r.onSelectFiles = handler
}

// OnFileReceived sets the callback for when a file is received.
func (r *RTCReceiver) OnFileReceived(handler func(filename string, size int64, sender string)) {
	r.onFileReceived = handler
}

// SetSenderPublicKey sets the sender's public key for token verification.
// This is typically obtained through the PAIR flow.
func (r *RTCReceiver) SetSenderPublicKey(key crypto.VerifyingKey) {
	r.senderPublicKey = key
}

// SetStrictVerification enables strict token verification mode.
// When enabled, transfers will fail if token verification fails.
func (r *RTCReceiver) SetStrictVerification(strict bool) {
	r.strictVerification = strict
}

// SetRequirePairing enables pairing requirement.
// When enabled, the receiver will request PAIR before accepting files from unknown senders.
func (r *RTCReceiver) SetRequirePairing(require bool) {
	r.requirePairing = require
}

// SetExtensionRoutes sets extension-to-directory routing.
// Keys should be lowercase extensions without dots (e.g., "epub", "pdf").
func (r *RTCReceiver) SetExtensionRoutes(routes map[string]string) {
	r.extRoutes = routes
}

// prepareFilesForReceive creates files and generates tokens for accepted file IDs.
// Returns a map of fileId -> token for successfully prepared files.
func (r *RTCReceiver) prepareFilesForReceive(acceptedIDs []string) map[string]string {
	fileTokens := make(map[string]string)
	for _, id := range acceptedIDs {
		// Find the file metadata first
		var targetFile *RTCFileDto
		for i := range r.files {
			if r.files[i].ID == id {
				targetFile = &r.files[i]
				break
			}
		}
		if targetFile == nil {
			slog.Warn("File ID not found in file list", "id", id)
			continue
		}

		// Determine save directory and create it
		saveDir := r.getSaveDir(targetFile.FileName)
		if err := os.MkdirAll(saveDir, 0755); err != nil {
			slog.Error("Failed to create save directory", "dir", saveDir, "error", err)
			continue
		}

		// Atomically create file with unique name (prevents race conditions)
		file, path, err := session.CreateUniqueFile(saveDir, targetFile.FileName)
		if err != nil {
			slog.Error("Failed to create unique file", "error", err)
			continue
		}

		// Only add the token since file was created successfully
		// Use crypto/rand for unpredictable tokens instead of time-based
		token := crypto.GenerateSecureToken()
		fileTokens[id] = token
		r.fileTokens[id] = token
		r.fileWriters[id] = file
		r.filePaths[id] = path
		r.fileHashers[id] = sha256.New()
		slog.Info("Ready to receive", "file", filepath.Base(path))
	}
	return fileTokens
}

// sendError sends an error response to the peer.
func (r *RTCReceiver) sendError(message string) {
	if r.peer == nil {
		return
	}
	errResp := RTCErrorResponse{Error: message}
	_ = r.peer.SendJSON(errResp)
}

// getSaveDir returns the appropriate save directory for a filename.
func (r *RTCReceiver) getSaveDir(filename string) string {
	if r.extRoutes == nil {
		return r.saveDir
	}

	ext := filepath.Ext(filename)
	if ext == "" {
		return r.saveDir
	}

	// Remove leading dot and lowercase
	ext = strings.ToLower(ext[1:])

	if dir, ok := r.extRoutes[ext]; ok {
		return dir
	}

	// Check for "default" route
	if dir, ok := r.extRoutes["default"]; ok {
		return dir
	}

	return r.saveDir
}

// AcceptOffer accepts an incoming WebRTC offer.
func (r *RTCReceiver) AcceptOffer(offer signaling.WsServerMessage) error {
	if offer.Peer == nil {
		return fmt.Errorf("offer missing peer info")
	}

	// Clean up any previous connection
	r.mu.Lock()
	hadPreviousPeer := r.peer != nil
	if r.peer != nil {
		_ = r.peer.Close()
		r.peer = nil
	}
	// Close any open file writers
	for _, f := range r.fileWriters {
		_ = f.Close()
	}
	r.fileWriters = make(map[string]*os.File)
	r.fileTokens = make(map[string]string)
	r.filePaths = make(map[string]string)
	r.fileHashers = make(map[string]hash.Hash)
	r.files = nil
	r.acceptedIDs = nil
	r.currentFileID = ""
	r.remoteNonce = nil
	r.localNonce = nil
	r.finalNonce = nil
	r.pinAttempts = 0
	r.mu.Unlock()

	if hadPreviousPeer {
		slog.Info("Cleaned up previous connection")
	}

	sdp, err := signaling.DecompressSDP(offer.SDP)
	if err != nil {
		return fmt.Errorf("failed to decompress SDP: %w", err)
	}

	peer, err := NewPeerConnection(PeerConfig{
		STUNServers: DefaultSTUNServers,
		IsInitiator: false,
	})
	if err != nil {
		return fmt.Errorf("failed to create peer connection: %w", err)
	}
	r.peer = peer
	r.state = stateWaitNonce

	peer.OnMessage(r.handleMessage)

	answer, err := peer.AcceptOffer(sdp)
	if err != nil {
		_ = peer.Close()
		return fmt.Errorf("failed to accept offer: %w", err)
	}

	if err := r.signaling.SendAnswer(offer.SessionID, offer.Peer.ID, answer); err != nil {
		_ = peer.Close()
		return fmt.Errorf("failed to send answer: %w", err)
	}

	slog.Info("Sent answer", "peer", offer.Peer.Alias, "session", offer.SessionID)
	return nil
}

// handleMessage processes incoming data channel messages.
func (r *RTCReceiver) handleMessage(data []byte) {
	r.mu.Lock()
	defer r.mu.Unlock()

	slog.Debug("Message received", "state", r.state, "len", len(data))

	// Check for delimiter (string message with len <= 1, like "0")
	if len(data) <= 1 {
		slog.Debug("Delimiter received")
		// If we were receiving a file, this signals end of all transfers
		if r.state == stateReceivingFiles && r.currentFileID != "" {
			r.finishCurrentFile()
			slog.Info("All files received, transfer complete")
			// Close the peer connection after transfer (like official impl)
			// Capture and clear peer reference to prevent double-close
			peer := r.peer
			r.peer = nil
			if peer != nil {
				go func(p *PeerConnection) {
					time.Sleep(100 * time.Millisecond) // Brief delay to ensure response is sent
					_ = p.Close()
				}(peer)
			}
		}
		return
	}

	// If we're receiving file binary data (non-JSON)
	if r.state == stateReceivingFiles && r.currentFileID != "" {
		// Check if this is a new file header (JSON) or binary data
		if data[0] == '{' {
			// This might be a file header for next file
			var header RTCSendFileHeader
			if err := json.Unmarshal(data, &header); err == nil && header.ID != "" {
				// Finish current file before starting next
				r.finishCurrentFile()
				slog.Info("Received file header", "id", header.ID)
				r.currentFileID = header.ID
				return
			}
		}
		r.handleBinaryData(data)
		return
	}

	// Parse message type
	msg, msgType, err := ParseRTCMessage(data)
	if err != nil || msg == nil {
		// Could be binary data in wrong state, or malformed JSON
		if r.state == stateWaitFiles && data[0] != '{' {
			// Binary data without header - might be continuation
			slog.Debug("Possible binary data, treating as file content")
			r.handleBinaryData(data)
			return
		}
		slog.Warn("Failed to parse RTC message", "error", err)
		return
	}

	slog.Debug("Parsed RTC message", "type", msgType)

	switch r.state {
	case stateWaitNonce:
		r.handleNonce(msg, msgType)
	case stateWaitToken:
		r.handleToken(msg, msgType)
	case stateWaitPin:
		r.handlePin(msg, msgType)
	case stateWaitFileList:
		r.handleFileList(msg, msgType, data)
	case stateWaitPairResponse:
		r.handlePairResponse(msg, msgType, data)
	case stateWaitFiles:
		r.handleFileHeader(msg, msgType)
	}
}

// handleNonce processes the nonce message from sender.
func (r *RTCReceiver) handleNonce(msg interface{}, msgType string) {
	if msgType != "nonce" {
		slog.Warn("Expected nonce, got", "type", msgType)
		return
	}

	nonceMsg, ok := msg.(*RTCNonceMessage)
	if !ok {
		slog.Error("Invalid message type for nonce", "got", fmt.Sprintf("%T", msg))
		r.sendError("internal error: message type mismatch")
		return
	}
	remoteNonce, err := crypto.DecodeNonce(nonceMsg.Nonce)
	if err != nil {
		slog.Error("Failed to decode remote nonce", "error", err)
		r.sendError("invalid nonce format")
		return
	}
	r.remoteNonce = remoteNonce

	// Generate and send our nonce
	localNonce, err := crypto.GenerateNonce()
	if err != nil {
		slog.Error("Failed to generate nonce", "error", err)
		r.sendError("internal error: nonce generation failed")
		return
	}
	r.localNonce = localNonce

	// Final nonce = sender_nonce || receiver_nonce
	// Use explicit allocation to avoid modifying underlying arrays
	r.finalNonce = make([]byte, len(r.remoteNonce)+len(r.localNonce))
	copy(r.finalNonce, r.remoteNonce)
	copy(r.finalNonce[len(r.remoteNonce):], r.localNonce)

	response := RTCNonceMessage{
		Nonce: crypto.EncodeNonce(localNonce),
	}
	if err := r.peer.SendJSON(response); err != nil {
		slog.Error("Failed to send nonce response", "error", err)
		return
	}

	slog.Info("Nonce exchange complete")
	r.state = stateWaitToken
}

// handleToken processes the token message from sender.
func (r *RTCReceiver) handleToken(msg interface{}, msgType string) {
	if msgType != "token_request" {
		slog.Warn("Expected token_request, got", "type", msgType)
		return
	}

	tokenReq, ok := msg.(*RTCTokenRequest)
	if !ok {
		slog.Error("Invalid message type for token_request", "got", fmt.Sprintf("%T", msg))
		r.sendError("internal error: message type mismatch")
		return
	}
	tokenPreview := tokenReq.Token
	if len(tokenPreview) > tokenPreviewLength {
		tokenPreview = tokenPreview[:tokenPreviewLength] + "..."
	}
	slog.Info("Received token from sender", "token", tokenPreview)

	// Optionally verify sender's token if we have their public key
	if r.senderPublicKey != nil {
		if err := crypto.VerifyTokenNonce(r.senderPublicKey, tokenReq.Token, r.finalNonce); err != nil {
			slog.Warn("Sender token verification failed", "error", err)
			if r.strictVerification {
				response := RTCTokenResponse{Status: "INVALID_SIGNATURE"}
				_ = r.peer.SendJSON(response)
				slog.Error("Rejecting sender due to invalid token signature")
				return
			}
			// In lenient mode, log warning but continue
			slog.Warn("Continuing despite token verification failure (strict mode disabled)")
		} else {
			slog.Info("Sender token verified successfully")
		}
	}

	// Generate our token
	token, err := r.signingKey.GenerateTokenWithNonce(r.finalNonce)
	if err != nil {
		slog.Error("Failed to generate token", "error", err)
		r.sendError("internal error: token generation failed")
		return
	}

	// Send token response (with or without PIN requirement)
	var response RTCTokenResponse
	if r.pin != "" {
		response = RTCTokenResponse{Status: "PIN_REQUIRED", Token: token}
	} else {
		response = RTCTokenResponse{Status: "OK", Token: token}
	}

	_ = r.peer.SendJSON(response)

	slog.Info("Token exchange complete", "status", response.Status)
	if response.Status == "PIN_REQUIRED" {
		r.state = stateWaitPin
	} else {
		r.state = stateWaitFileList
	}
}

// handlePin processes the PIN message from sender.
func (r *RTCReceiver) handlePin(msg interface{}, msgType string) {
	if msgType != "pin" {
		slog.Warn("Expected pin, got", "type", msgType)
		return
	}

	pinMsg, ok := msg.(*RTCPinMessage)
	if !ok {
		slog.Error("Invalid message type for pin", "got", fmt.Sprintf("%T", msg))
		r.sendError("internal error: message type mismatch")
		return
	}
	slog.Info("Received PIN challenge")

	// Use constant-time comparison to prevent timing attacks
	if subtle.ConstantTimeCompare([]byte(pinMsg.Pin), []byte(r.pin)) == 1 {
		slog.Info("PIN correct")
		response := RTCPinReceivingResponse{Status: "OK"}
		_ = r.peer.SendJSON(response)
		r.state = stateWaitFileList
		return
	}

	r.pinAttempts++
	slog.Warn("Incorrect PIN", "attempt", r.pinAttempts)

	if r.pinAttempts >= maxPINAttempts {
		slog.Error("Too many PIN attempts, closing connection")
		response := RTCPinReceivingResponse{Status: "TOO_MANY_ATTEMPTS"}
		_ = r.peer.SendJSON(response)
		_ = r.Close()
		return
	}

	response := RTCPinReceivingResponse{Status: "PIN_REQUIRED"}
	_ = r.peer.SendJSON(response)
}

// handleFileList processes the file list from sender.
func (r *RTCReceiver) handleFileList(_ interface{}, msgType string, data []byte) {
	// File list comes as RTCPinSendingResponse with status OK
	if msgType != "file_list" && msgType != "status_OK" {
		slog.Warn("Expected file_list, got", "type", msgType)
		return
	}

	// Parse as RTCPinSendingResponse
	var fileListMsg RTCPinSendingResponse
	if err := json.Unmarshal(data, &fileListMsg); err != nil {
		slog.Error("Failed to parse file list", "error", err)
		return
	}

	r.files = fileListMsg.Files
	slog.Info("Received file list", "count", len(r.files))

	for _, f := range r.files {
		slog.Info("File", "name", f.FileName, "size", f.Size)
	}

	// Select files to accept
	var acceptedIDs []string
	if r.onSelectFiles != nil {
		acceptedIDs = r.onSelectFiles(r.files)
	} else {
		// Accept all by default
		for _, f := range r.files {
			acceptedIDs = append(acceptedIDs, f.ID)
		}
	}
	r.acceptedIDs = acceptedIDs

	if len(acceptedIDs) == 0 {
		response := RTCFileListResponse{Status: "DECLINED"}
		if err := r.peer.SendJSONBinary(response); err != nil {
			slog.Error("Failed to send decline response", "error", err)
		}
		if err := r.peer.SendDelimiter(); err != nil {
			slog.Error("Failed to send delimiter", "error", err)
		}
		slog.Info("Declined all files")
		return
	}

	// Check if PAIR is required
	if r.requirePairing && r.senderPublicKey == nil {
		// Initiate PAIR flow
		slog.Info("Initiating PAIR flow - sender not yet trusted")
		r.pendingFiles = r.files // Store files for after PAIR completes

		response := RTCFileListResponse{
			Status:    "PAIR",
			PublicKey: r.signingKey.PublicKeyPEM(),
		}
		if err := r.peer.SendJSONBinary(response); err != nil {
			slog.Error("Failed to send PAIR request", "error", err)
			return
		}
		if err := r.peer.SendDelimiter(); err != nil {
			slog.Error("Failed to send delimiter after PAIR request", "error", err)
			return
		}
		slog.Info("Sent PAIR request with our public key, waiting for sender's response")
		r.state = stateWaitPairResponse
		return
	}

	// Prepare files and generate tokens
	fileTokens := r.prepareFilesForReceive(acceptedIDs)

	// Send acceptance with file tokens as binary (official protocol uses chunked binary)
	response := RTCFileListResponse{
		Status: "OK",
		Files:  fileTokens,
	}
	if err := r.peer.SendJSONBinary(response); err != nil {
		slog.Error("Failed to send file acceptance", "error", err)
		return
	}

	// Send delimiter to signal end of our response (required by protocol)
	if err := r.peer.SendDelimiter(); err != nil {
		slog.Error("Failed to send delimiter", "error", err)
		return
	}

	slog.Info("Sent file acceptance and delimiter", "count", len(fileTokens))
	r.state = stateWaitFiles
}

// handlePairResponse processes the PAIR response from sender.
func (r *RTCReceiver) handlePairResponse(_ interface{}, msgType string, data []byte) {
	if msgType != "pair_response" && msgType != "status_OK" && msgType != "status_PAIR_DECLINED" && msgType != "status_INVALID_SIGNATURE" {
		slog.Warn("Expected pair response, got", "type", msgType)
		return
	}

	var resp RTCPairResponse
	if err := json.Unmarshal(data, &resp); err != nil {
		slog.Error("Failed to parse PAIR response", "error", err)
		return
	}

	switch resp.Status {
	case "OK":
		slog.Info("PAIR accepted by sender", "hasPublicKey", resp.PublicKey != "")
		if resp.PublicKey != "" {
			// Parse and store sender's public key for future verification
			key, err := crypto.ParsePublicKeyPEM(resp.PublicKey)
			if err != nil {
				slog.Error("Failed to parse sender's public key", "error", err)
			} else {
				r.senderPublicKey = key
				slog.Info("Stored sender's public key for verification")
			}
		}

		// Now proceed with accepting files - send OK response with file tokens
		r.acceptFilesAfterPair()

	case "PAIR_DECLINED":
		slog.Warn("PAIR declined by sender")
		// Fall back to normal acceptance without pairing
		r.acceptFilesAfterPair()

	case "INVALID_SIGNATURE":
		slog.Error("Sender rejected our signature")
		// Close the connection
		return
	}
}

// acceptFilesAfterPair sends the file acceptance response after PAIR flow completes.
func (r *RTCReceiver) acceptFilesAfterPair() {
	// Prepare files and generate tokens
	fileTokens := r.prepareFilesForReceive(r.acceptedIDs)

	// Send acceptance with file tokens
	response := RTCFileListResponse{
		Status: "OK",
		Files:  fileTokens,
	}
	if err := r.peer.SendJSONBinary(response); err != nil {
		slog.Error("Failed to send file acceptance after PAIR", "error", err)
		return
	}

	if err := r.peer.SendDelimiter(); err != nil {
		slog.Error("Failed to send delimiter after PAIR acceptance", "error", err)
		return
	}

	slog.Info("Sent file acceptance after PAIR", "count", len(fileTokens))
	r.state = stateWaitFiles
}

// handleFileHeader processes file header before binary data.
func (r *RTCReceiver) handleFileHeader(msg interface{}, msgType string) {
	if msgType != "file_header" {
		slog.Debug("Non-file-header in file receive state", "type", msgType)
		return
	}

	header, ok := msg.(*RTCSendFileHeader)
	if !ok {
		slog.Error("Invalid message type for file_header", "got", fmt.Sprintf("%T", msg))
		return
	}
	slog.Info("Receiving file", "id", header.ID)
	r.currentFileID = header.ID
	r.state = stateReceivingFiles
}

// handleBinaryData writes received file data.
func (r *RTCReceiver) handleBinaryData(data []byte) {
	if f, ok := r.fileWriters[r.currentFileID]; ok {
		n, err := f.Write(data)
		if err != nil {
			slog.Error("Failed to write data", "error", err)
		} else {
			slog.Debug("Wrote file data", "fileId", r.currentFileID, "bytes", n)
			// Also write to hasher for checksum verification
			if h, ok := r.fileHashers[r.currentFileID]; ok {
				h.Write(data)
			}
		}
	} else {
		slog.Warn("No file writer for current file", "fileId", r.currentFileID)
	}
}

// finishCurrentFile closes the current file and sends a success response to the sender.
func (r *RTCReceiver) finishCurrentFile() {
	if r.currentFileID == "" {
		return
	}

	fileID := r.currentFileID
	success := true
	var errorMsg *string

	// Close and sync the file
	if f, ok := r.fileWriters[fileID]; ok {
		_ = f.Sync()
		_ = f.Close()
		delete(r.fileWriters, fileID)

		// Verify checksum if provided
		path, pathOk := r.filePaths[fileID]
		if h, ok := r.fileHashers[fileID]; ok {
			checksum := hex.EncodeToString(h.Sum(nil))
			delete(r.fileHashers, fileID)

			// Find expected checksum from metadata
			var expectedChecksum string
			var size int64
			for _, f := range r.files {
				if f.ID == fileID {
					expectedChecksum = f.SHA256
					size = f.Size
					break
				}
			}

			if expectedChecksum != "" && checksum != expectedChecksum {
				slog.Error("Checksum mismatch", "file", filepath.Base(path), "expected", expectedChecksum, "got", checksum)
				success = false
				msg := "checksum mismatch"
				errorMsg = &msg
				// Delete corrupted file
				if pathOk {
					_ = os.Remove(path)
				}
			} else if pathOk {
				savedFilename := filepath.Base(path)
				slog.Info("File received successfully", "file", savedFilename)

				// Call the onFileReceived callback
				if r.onFileReceived != nil {
					r.onFileReceived(savedFilename, size, "WebRTC")
				}
			}
		}
	}

	// Send response to sender (required by protocol)
	response := RTCSendFileResponse{
		ID:      fileID,
		Success: success,
		Error:   errorMsg,
	}
	if err := r.peer.SendJSON(response); err != nil {
		slog.Error("Failed to send file response", "error", err)
	}

	r.currentFileID = ""
}

// Close closes the receiver.
func (r *RTCReceiver) Close() error {
	for _, f := range r.fileWriters {
		_ = f.Close()
	}
	if r.peer != nil {
		return r.peer.Close()
	}
	return nil
}

// ListenForOffersWithContext listens for incoming WebRTC offers with context support.
// The listener stops when the context is cancelled or the signaling channel closes.
func (r *RTCReceiver) ListenForOffersWithContext(ctx context.Context, onOffer func(offer signaling.WsServerMessage)) {
	go func() {
		for {
			select {
			case <-ctx.Done():
				return
			case msg, ok := <-r.signaling.Messages():
				if !ok {
					return
				}
				if msg.Type == "OFFER" {
					onOffer(msg)
				}
			}
		}
	}()
}
