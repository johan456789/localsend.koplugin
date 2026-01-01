package session

import (
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"io"
	"log/slog"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"

	lserrors "localsend-cli/internal/localsend/constants"
	"localsend-cli/internal/models"
	"github.com/google/uuid"
)

type RecvSession struct {
	// filesCount must be first for 64-bit alignment on 32-bit ARM
	filesCount int64
	fileMetas  models.FileMetas
	fileTokens models.FileTokens
	mu         sync.RWMutex
	id         string
	clientIP   string // IP address of the client that initiated the session (per protocol spec Section 4.2)
	started    atomic.Bool
}

func NewRecvSession(sessionId string, clientIP string) (*RecvSession, error) {
	sess := &RecvSession{
		fileMetas:  make(models.FileMetas),
		fileTokens: make(models.FileTokens),
		id:         sessionId,
		clientIP:   clientIP,
	}

	return sess, nil
}

func (sess *RecvSession) AcceptFile(fileId string, fileMeta models.FileMeta) error {
	// reject upload request for a started session
	if sess.started.Load() {
		return lserrors.ErrBlockedByOthers
	}

	// unlikely, but check it anyway
	if fileId != fileMeta.Id {
		return lserrors.ErrUnknown
	}

	sess.mu.Lock()
	defer sess.mu.Unlock()

	// store the file metadata
	sess.fileMetas[fileId] = fileMeta

	// generate file token
	sess.fileTokens[fileId] = uuid.NewString()

	// increment files count (inside lock to prevent race condition)
	atomic.AddInt64(&sess.filesCount, 1)

	return nil
}

func (sess *RecvSession) Start() {
	sess.started.Store(true)
}

// maxUniquePathAttempts is the maximum number of attempts to find a unique filename
const maxUniquePathAttempts = 10000

// FindUniquePath returns a unique file path by appending a counter if the file already exists.
// For example: "file.txt" -> "file (1).txt" -> "file (2).txt"
// Returns an error if a unique path cannot be found after maxUniquePathAttempts.
func FindUniquePath(dir, filename string) (string, error) {
	path := filepath.Join(dir, filename)

	// If file doesn't exist, use the original name
	if _, err := os.Stat(path); os.IsNotExist(err) {
		return path, nil
	}

	// Split filename into name and extension
	ext := filepath.Ext(filename)
	name := strings.TrimSuffix(filename, ext)

	// Try incrementing counter until we find a unique name
	for i := 1; i <= maxUniquePathAttempts; i++ {
		newFilename := fmt.Sprintf("%s (%d)%s", name, i, ext)
		path = filepath.Join(dir, newFilename)
		if _, err := os.Stat(path); os.IsNotExist(err) {
			return path, nil
		}
	}

	return "", fmt.Errorf("could not find unique path after %d attempts for %s", maxUniquePathAttempts, filename)
}

func (sess *RecvSession) SaveFile(saveToDir string, fileId string, token string, clientIP string, fileData io.Reader) (string, error) {
	if sess.id == "" || fileId == "" || token == "" {
		return "", lserrors.ErrInvalidBody
	}

	// if a session is not started, it means the session is invalid
	if !sess.started.Load() {
		return "", lserrors.ErrRejected
	}

	// Validate client IP per protocol spec Section 4.2:
	// Return 403 for "Invalid token or IP address"
	if sess.clientIP != "" && clientIP != sess.clientIP {
		return "", lserrors.ErrRejected
	}

	sess.mu.RLock()
	expectedMeta, metaExist := sess.fileMetas[fileId]
	expectedToken, tokenExist := sess.fileTokens[fileId]
	sess.mu.RUnlock()

	// validate
	if !metaExist || !tokenExist || expectedToken != token {
		return "", lserrors.ErrRejected
	}

	// write the file data to disk while calculating checksum simultaneously
	saveAs, err := FindUniquePath(saveToDir, expectedMeta.Filename)
	if err != nil {
		slog.Error("Failed to find unique path", "error", err)
		return "", lserrors.ErrFileIO
	}

	// Ensure the directory exists (for extension routing to new directories)
	if err := os.MkdirAll(saveToDir, 0755); err != nil {
		slog.Error("Failed to create save directory", "dir", saveToDir, "error", err)
		return "", lserrors.ErrFileIO
	}

	hasher := sha256.New()
	file, err := os.Create(saveAs)
	if err != nil {
		return "", lserrors.ErrFileIO
	}
	defer func() { _ = file.Close() }()

	writer := io.MultiWriter(file, hasher)
	_, err = io.Copy(writer, fileData)
	if err != nil {
		return "", lserrors.ErrFileIO
	}

	// calculate checksum if it's provided
	if expectedMeta.Checksum != "" {
		checksum := hex.EncodeToString(hasher.Sum(nil))

		if checksum != expectedMeta.Checksum {
			return "", lserrors.ErrChecksum
		}
	}

	slog.Info("Recv file", "file", saveAs, "session", sess.id)

	// remove finished file
	atomic.AddInt64(&sess.filesCount, -1)

	// end this session if it is the last file it received
	if count := atomic.LoadInt64(&sess.filesCount); count == 0 {
		sess.End()
	}

	// Return the actual saved filename (may differ from original if renamed due to conflict)
	return filepath.Base(saveAs), nil
}

func (sess *RecvSession) FileTokens() models.FileTokens {
	sess.mu.RLock()
	defer sess.mu.RUnlock()

	// Return a copy to prevent external modification
	result := make(models.FileTokens, len(sess.fileTokens))
	for k, v := range sess.fileTokens {
		result[k] = v
	}
	return result
}

func (sess *RecvSession) GetFileMeta(fileId string) (models.FileMeta, bool) {
	sess.mu.RLock()
	defer sess.mu.RUnlock()

	meta, ok := sess.fileMetas[fileId]
	return meta, ok
}

func (sess *RecvSession) End() {
	if sess.started.Load() { // make sure it ends once
		sess.started.Store(false)
		atomic.StoreInt64(&sess.filesCount, 0)

		slog.Info("Session done", "session", sess.id)
	}
}

func (sess *RecvSession) Stopped() bool {
	fileLefts := atomic.LoadInt64(&sess.filesCount)

	return (!sess.started.Load()) || (fileLefts == 0)
}
