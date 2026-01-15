package utils

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
)

// MaxUniquePathAttempts is the maximum number of attempts to find a unique path.
const MaxUniquePathAttempts = 10000

// FindUniqueFolderName finds a unique folder name in saveDir, appending a counter if needed.
// For example: "Photos" -> "Photos (1)" -> "Photos (2)" if folders already exist.
func FindUniqueFolderName(saveDir, folderName string) (string, error) {
	path := filepath.Join(saveDir, folderName)
	if _, err := os.Stat(path); os.IsNotExist(err) {
		return folderName, nil // doesn't exist, use as-is
	}

	// Folder exists, find unique name
	for i := 1; i <= MaxUniquePathAttempts; i++ {
		newName := fmt.Sprintf("%s (%d)", folderName, i)
		path = filepath.Join(saveDir, newName)
		if _, err := os.Stat(path); os.IsNotExist(err) {
			return newName, nil
		}
	}
	return "", fmt.Errorf("could not find unique folder name after %d attempts for %s", MaxUniquePathAttempts, folderName)
}

// CreateUniqueFile atomically creates a file with a unique name, appending a counter if needed.
// For example: "file.txt" -> "file (1).txt" -> "file (2).txt"
// Uses O_CREATE|O_EXCL to prevent race conditions between concurrent uploads.
// Returns the opened file and its path, or an error if a unique name cannot be found.
func CreateUniqueFile(dir, filename string) (*os.File, string, error) {
	path := filepath.Join(dir, filename)

	// Try the original filename first
	file, err := os.OpenFile(path, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0644)
	if err == nil {
		return file, path, nil
	}
	if !os.IsExist(err) {
		// Some other error (permissions, etc.)
		return nil, "", err
	}

	// File exists, try with counter suffix
	ext := filepath.Ext(filename)
	name := strings.TrimSuffix(filename, ext)

	for i := 1; i <= MaxUniquePathAttempts; i++ {
		newFilename := fmt.Sprintf("%s (%d)%s", name, i, ext)
		path = filepath.Join(dir, newFilename)

		file, err = os.OpenFile(path, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0644)
		if err == nil {
			return file, path, nil
		}
		if !os.IsExist(err) {
			// Some other error (permissions, etc.)
			return nil, "", err
		}
	}

	return nil, "", fmt.Errorf("could not create unique file after %d attempts for %s", MaxUniquePathAttempts, filename)
}
