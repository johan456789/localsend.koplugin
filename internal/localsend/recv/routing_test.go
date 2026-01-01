package recv

import (
	"os"
	"path/filepath"
	"testing"
)

func TestExtensionRouter_GetSaveDir(t *testing.T) {
	router := NewExtensionRouter("/default")
	router.routes["epub"] = "/books"
	router.routes["pdf"] = "/pdfs"

	tests := []struct {
		filename string
		want     string
	}{
		{"book.epub", "/books"},
		{"book.EPUB", "/books"}, // case insensitive
		{"document.pdf", "/pdfs"},
		{"document.PDF", "/pdfs"},
		{"image.png", "/default"},   // no route, use default
		{"noextension", "/default"}, // no extension, use default
		{"file.unknown", "/default"},
	}

	for _, tt := range tests {
		t.Run(tt.filename, func(t *testing.T) {
			got := router.GetSaveDir(tt.filename)
			if got != tt.want {
				t.Errorf("GetSaveDir(%q) = %q, want %q", tt.filename, got, tt.want)
			}
		})
	}
}

func TestExtensionRouter_LoadFromFile(t *testing.T) {
	// Create temp config file
	tmpDir := t.TempDir()
	configPath := filepath.Join(tmpDir, "ext_routing.json")

	config := `{
		"epub": "/mnt/books",
		"pdf": "/mnt/pdfs",
		"default": "/mnt/downloads"
	}`

	if err := os.WriteFile(configPath, []byte(config), 0644); err != nil {
		t.Fatalf("Failed to write config: %v", err)
	}

	router := NewExtensionRouter("/original-default")
	if err := router.LoadFromFile(configPath); err != nil {
		t.Fatalf("LoadFromFile failed: %v", err)
	}

	// Check routes were loaded
	if !router.HasRoutes() {
		t.Error("Expected HasRoutes() to be true")
	}

	// Check specific routes
	if got := router.GetSaveDir("book.epub"); got != "/mnt/books" {
		t.Errorf("GetSaveDir(book.epub) = %q, want /mnt/books", got)
	}

	if got := router.GetSaveDir("doc.pdf"); got != "/mnt/pdfs" {
		t.Errorf("GetSaveDir(doc.pdf) = %q, want /mnt/pdfs", got)
	}

	// Check default was overridden
	if got := router.GetSaveDir("file.unknown"); got != "/mnt/downloads" {
		t.Errorf("GetSaveDir(file.unknown) = %q, want /mnt/downloads", got)
	}
}

func TestExtensionRouter_HasRoutes(t *testing.T) {
	router := NewExtensionRouter("/default")
	if router.HasRoutes() {
		t.Error("Expected HasRoutes() to be false for empty router")
	}

	router.routes["epub"] = "/books"
	if !router.HasRoutes() {
		t.Error("Expected HasRoutes() to be true after adding route")
	}
}
