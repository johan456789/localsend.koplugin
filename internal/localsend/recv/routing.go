package recv

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
)

// ExtensionRouter routes files to different directories based on their extension.
type ExtensionRouter struct {
	routes     map[string]string // lowercase ext (without dot) -> directory
	defaultDir string
}

// NewExtensionRouter creates a new router with the given default directory.
func NewExtensionRouter(defaultDir string) *ExtensionRouter {
	return &ExtensionRouter{
		routes:     make(map[string]string),
		defaultDir: defaultDir,
	}
}

// LoadFromFile loads routing configuration from a JSON file.
// The JSON should be an object mapping extensions to directories:
//
//	{
//	  "epub": "/path/to/books",
//	  "pdf": "/path/to/pdfs",
//	  "default": "/path/to/default"
//	}
func (r *ExtensionRouter) LoadFromFile(path string) error {
	data, err := os.ReadFile(path)
	if err != nil {
		return err
	}

	var config map[string]string
	if err := json.Unmarshal(data, &config); err != nil {
		return err
	}

	for ext, dir := range config {
		ext = strings.ToLower(strings.TrimPrefix(ext, "."))
		if ext == "default" {
			r.defaultDir = dir
		} else {
			r.routes[ext] = dir
		}
	}

	return nil
}

// GetSaveDir returns the appropriate save directory for a file based on its extension.
// Falls back to the default directory if no specific route is configured.
func (r *ExtensionRouter) GetSaveDir(filename string) string {
	ext := filepath.Ext(filename)
	if ext == "" {
		return r.defaultDir
	}

	// Remove leading dot and lowercase
	ext = strings.ToLower(ext[1:])

	if dir, ok := r.routes[ext]; ok {
		return dir
	}

	return r.defaultDir
}

// HasRoutes returns true if any extension-specific routes are configured.
func (r *ExtensionRouter) HasRoutes() bool {
	return len(r.routes) > 0
}

// EnsureDirectories creates all configured directories if they don't exist.
func (r *ExtensionRouter) EnsureDirectories() error {
	dirs := make(map[string]bool)
	dirs[r.defaultDir] = true
	for _, dir := range r.routes {
		dirs[dir] = true
	}

	for dir := range dirs {
		if err := os.MkdirAll(dir, 0755); err != nil {
			return err
		}
	}

	return nil
}
