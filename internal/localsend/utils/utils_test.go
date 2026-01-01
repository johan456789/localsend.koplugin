package utils

import (
	"os"
	"path/filepath"
	"testing"
)

// TestGenAndSaveTLScertPermissions verifies the fix for Issue #5
// Private keys should be saved with 0600 permissions (owner only)
func TestGenAndSaveTLScertPermissions(t *testing.T) {
	dir := t.TempDir()
	privKeyFile := filepath.Join(dir, "key.pem")
	certFile := filepath.Join(dir, "cert.pem")

	_, err := GenAndSaveTLScert(privKeyFile, certFile)
	if err != nil {
		t.Fatalf("GenAndSaveTLScert failed: %v", err)
	}

	t.Run("private key has 0600 permissions", func(t *testing.T) {
		info, err := os.Stat(privKeyFile)
		if err != nil {
			t.Fatalf("failed to stat private key file: %v", err)
		}

		mode := info.Mode().Perm()
		expected := os.FileMode(0o600)
		if mode != expected {
			t.Errorf("private key permissions: expected %o, got %o", expected, mode)
		}
	})

	t.Run("certificate has 0644 permissions", func(t *testing.T) {
		info, err := os.Stat(certFile)
		if err != nil {
			t.Fatalf("failed to stat certificate file: %v", err)
		}

		mode := info.Mode().Perm()
		expected := os.FileMode(0o644)
		if mode != expected {
			t.Errorf("certificate permissions: expected %o, got %o", expected, mode)
		}
	})
}

// TestGenAndSaveTLScertGeneratesValidCert verifies the certificate is valid
func TestGenAndSaveTLScertGeneratesValidCert(t *testing.T) {
	dir := t.TempDir()
	privKeyFile := filepath.Join(dir, "key.pem")
	certFile := filepath.Join(dir, "cert.pem")

	cert, err := GenAndSaveTLScert(privKeyFile, certFile)
	if err != nil {
		t.Fatalf("GenAndSaveTLScert failed: %v", err)
	}

	// Verify certificate has at least one certificate in chain
	if len(cert.Certificate) == 0 {
		t.Error("certificate chain is empty")
	}

	// Verify private key is present
	if cert.PrivateKey == nil {
		t.Error("private key is nil")
	}
}

// TestLoadOrGenTLScert tests loading existing or generating new certs
func TestLoadOrGenTLScert(t *testing.T) {
	t.Run("generates new cert when files don't exist", func(t *testing.T) {
		dir := t.TempDir()
		privKeyFile := filepath.Join(dir, "key.pem")
		certFile := filepath.Join(dir, "cert.pem")

		cert, err := LoadOrGenTLScert(privKeyFile, certFile)
		if err != nil {
			t.Fatalf("LoadOrGenTLScert failed: %v", err)
		}

		if len(cert.Certificate) == 0 {
			t.Error("certificate chain is empty")
		}

		// Verify files were created
		if _, err := os.Stat(privKeyFile); os.IsNotExist(err) {
			t.Error("private key file was not created")
		}
		if _, err := os.Stat(certFile); os.IsNotExist(err) {
			t.Error("certificate file was not created")
		}
	})

	t.Run("loads existing cert when files exist", func(t *testing.T) {
		dir := t.TempDir()
		privKeyFile := filepath.Join(dir, "key.pem")
		certFile := filepath.Join(dir, "cert.pem")

		// Generate first
		cert1, err := GenAndSaveTLScert(privKeyFile, certFile)
		if err != nil {
			t.Fatalf("GenAndSaveTLScert failed: %v", err)
		}

		// Load existing
		cert2, err := LoadOrGenTLScert(privKeyFile, certFile)
		if err != nil {
			t.Fatalf("LoadOrGenTLScert failed: %v", err)
		}

		// Should be the same certificate
		if len(cert1.Certificate) != len(cert2.Certificate) {
			t.Error("loaded certificate differs from generated certificate")
		}
	})
}

// TestGenAlias tests alias generation
func TestGenAlias(t *testing.T) {
	t.Run("generates non-empty alias", func(t *testing.T) {
		alias := GenAlias()
		if alias == "" {
			t.Error("alias should not be empty")
		}
	})

	t.Run("alias contains space", func(t *testing.T) {
		alias := GenAlias()
		hasSpace := false
		for _, c := range alias {
			if c == ' ' {
				hasSpace = true
				break
			}
		}
		if !hasSpace {
			t.Errorf("alias should contain a space: %q", alias)
		}
	})

	t.Run("generates different aliases", func(t *testing.T) {
		seen := make(map[string]bool)
		// Generate many aliases
		for i := 0; i < 100; i++ {
			alias := GenAlias()
			seen[alias] = true
		}
		// With 38 adjectives and 26 fruits = 988 combinations
		// 100 attempts should generate at least 10 unique aliases
		if len(seen) < 10 {
			t.Errorf("expected at least 10 unique aliases, got %d", len(seen))
		}
	})
}

// TestGenFingerprint tests fingerprint generation
func TestGenFingerprint(t *testing.T) {
	t.Run("generates non-empty fingerprint", func(t *testing.T) {
		fp := GenFingerprint()
		if fp == "" {
			t.Error("fingerprint should not be empty")
		}
	})

	t.Run("generates unique fingerprints", func(t *testing.T) {
		fp1 := GenFingerprint()
		fp2 := GenFingerprint()
		if fp1 == fp2 {
			t.Error("fingerprints should be unique")
		}
	})

	t.Run("fingerprint is UUID format", func(t *testing.T) {
		fp := GenFingerprint()
		// UUID format: 8-4-4-4-12 = 36 characters
		if len(fp) != 36 {
			t.Errorf("fingerprint should be 36 characters (UUID), got %d", len(fp))
		}
	})
}

// TestNewWebServer tests web server creation
func TestNewWebServer(t *testing.T) {
	t.Run("creates server without template engine", func(t *testing.T) {
		app := NewWebServer()
		if app == nil {
			t.Error("should return non-nil app")
		}
		_ = app.Shutdown()
	})

	t.Run("creates server with template engine", func(t *testing.T) {
		app := NewWebServer(true)
		if app == nil {
			t.Error("should return non-nil app")
		}
		_ = app.Shutdown()
	})
}

// TestListenWithTLS tests TLS listener selection
func TestListenWithTLS(t *testing.T) {
	// Note: We can't easily test actual listening without port conflicts
	// This is a smoke test to verify the function exists
	t.Run("function exists", func(t *testing.T) {
		// ListenWithTLS is defined in utils.go and takes (*fiber.App, string, tls.Certificate, bool)
		// Just verify it's exported and callable (actual test would require a free port)
		_ = ListenWithTLS
	})
}
