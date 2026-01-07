package utils

import (
	"errors"
	"path/filepath"
	"slices"
	"strings"
)

var (
	ErrAbsolutePath  = errors.New("absolute paths not allowed")
	ErrPathTraversal = errors.New("path traversal not allowed")
	ErrEmptyPath     = errors.New("empty path not allowed")
)

// SanitizeRelativePath validates a relative path from the LocalSend protocol.
// It allows subdirectory paths like "Photos/Summer/beach.jpg" but rejects
// directory traversal attacks like "../../../etc/passwd".
//
// The function:
//   - Converts protocol path separators (/) to OS-specific separators
//   - Cleans the path (resolves . and ..)
//   - Rejects absolute paths
//   - Rejects paths that would escape the root directory via ".."
//
// Returns the cleaned, OS-specific path or an error if the path is unsafe.
func SanitizeRelativePath(filename string) (string, error) {
	if filename == "" {
		return "", ErrEmptyPath
	}

	// Convert protocol separators (/) to OS-specific
	osPath := filepath.FromSlash(filename)

	// Clean the path (resolves . and ..)
	cleaned := filepath.Clean(osPath)

	// Reject empty or root-only results
	if cleaned == "" || cleaned == "." {
		return "", ErrEmptyPath
	}

	// Reject absolute paths
	if filepath.IsAbs(cleaned) {
		return "", ErrAbsolutePath
	}

	// Reject paths that escape upward (start with ".." after cleaning)
	// filepath.Clean normalizes "foo/../../../bar" to "../../bar"
	if strings.HasPrefix(cleaned, ".."+string(filepath.Separator)) || cleaned == ".." {
		return "", ErrPathTraversal
	}

	// Double-check: verify no path component is ".."
	// This catches edge cases that might slip through
	parts := strings.Split(cleaned, string(filepath.Separator))
	if slices.Contains(parts, "..") {
		return "", ErrPathTraversal
	}

	return cleaned, nil
}

// ToProtocolPath converts an OS-specific path to protocol format (forward slashes).
// This should be used when preparing filenames to send over the LocalSend protocol.
func ToProtocolPath(osPath string) string {
	return filepath.ToSlash(osPath)
}
