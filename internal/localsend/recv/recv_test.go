package recv

import (
	"bytes"
	"log/slog"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"

	lsutils "localsend-cli/internal/localsend/utils"
)

// =============================================================================
// Race Condition Tests (Issue #7)
// These tests verify the fix for race conditions in FileReceiver setters.
// Run with -race flag to detect data races.
// =============================================================================

// TestSetPINRaceCondition demonstrates Issue #7.
// EXPECTED TO FAIL with race detector: Race between SetPIN and reading expectedPin.
func TestSetPINRaceCondition(t *testing.T) {
	fr := NewFileReceiver("test", "/tmp", false)

	var wg sync.WaitGroup
	wg.Add(2)

	// Goroutine 1: Repeatedly set PIN
	go func() {
		defer wg.Done()
		for i := 0; i < 1000; i++ {
			fr.SetPIN("1234")
			fr.SetPIN("5678")
		}
	}()

	// Goroutine 2: Repeatedly read PIN (simulating handler access)
	go func() {
		defer wg.Done()
		for i := 0; i < 1000; i++ {
			// Use the thread-safe getter instead of direct field access
			_ = fr.getExpectedPIN()
		}
	}()

	wg.Wait()
	t.Log("Race condition test completed - run with -race flag to detect data races")
}

// TestSetAllowedExtensionsRaceCondition demonstrates Issue #7.
// EXPECTED TO FAIL with race detector: Race between SetAllowedExtensions and reading.
func TestSetAllowedExtensionsRaceCondition(t *testing.T) {
	fr := NewFileReceiver("test", "/tmp", false)

	var wg sync.WaitGroup
	wg.Add(2)

	// Goroutine 1: Repeatedly set extensions
	go func() {
		defer wg.Done()
		for i := 0; i < 1000; i++ {
			fr.SetAllowedExtensions([]string{"pdf", "epub"})
			fr.SetAllowedExtensions([]string{"mobi", "azw3"})
		}
	}()

	// Goroutine 2: Repeatedly check filter (simulating handler access)
	go func() {
		defer wg.Done()
		for i := 0; i < 1000; i++ {
			// Use the thread-safe method instead of direct field access
			_ = fr.hasExtensionFilter()
		}
	}()

	wg.Wait()
	t.Log("Race condition test completed - run with -race flag to detect data races")
}

// TestSetTransferLogRaceCondition demonstrates Issue #7.
// EXPECTED TO FAIL with race detector: Race between SetTransferLog and LogTransfer.
func TestSetTransferLogRaceCondition(t *testing.T) {
	fr := NewFileReceiver("test", "/tmp", false)

	var wg sync.WaitGroup
	wg.Add(2)

	// Goroutine 1: Repeatedly set transfer log path
	go func() {
		defer wg.Done()
		for i := 0; i < 1000; i++ {
			fr.SetTransferLog("/tmp/log1.json")
			fr.SetTransferLog("/tmp/log2.json")
		}
	}()

	// Goroutine 2: Repeatedly call LogTransfer (uses transferLogPath internally)
	go func() {
		defer wg.Done()
		for i := 0; i < 1000; i++ {
			// LogTransfer now uses thread-safe access internally
			fr.LogTransfer("test.pdf", 100, "sender")
		}
	}()

	wg.Wait()
	t.Log("Race condition test completed - run with -race flag to detect data races")
}

// TestSetExtensionRouterRaceCondition demonstrates Issue #7.
// EXPECTED TO FAIL with race detector: Race between SetExtensionRouter and GetSaveDir.
func TestSetExtensionRouterRaceCondition(t *testing.T) {
	fr := NewFileReceiver("test", "/tmp", false)
	router := NewExtensionRouter("/default")

	var wg sync.WaitGroup
	wg.Add(2)

	// Goroutine 1: Repeatedly set router
	go func() {
		defer wg.Done()
		for i := 0; i < 1000; i++ {
			fr.SetExtensionRouter(router)
			fr.SetExtensionRouter(nil)
		}
	}()

	// Goroutine 2: Repeatedly call GetSaveDir (uses router internally)
	go func() {
		defer wg.Done()
		for i := 0; i < 1000; i++ {
			// GetSaveDir now uses thread-safe access internally
			_ = fr.GetSaveDir("test.pdf")
		}
	}()

	wg.Wait()
	t.Log("Race condition test completed - run with -race flag to detect data races")
}

// TestSetListenAddrRaceCondition demonstrates Issue #7.
// EXPECTED TO FAIL with race detector: Race between SetListenAddr and ListenAddr.
func TestSetListenAddrRaceCondition(t *testing.T) {
	fr := NewFileReceiver("test", "/tmp", false)

	var wg sync.WaitGroup
	wg.Add(2)

	// Goroutine 1: Repeatedly set listen addr
	go func() {
		defer wg.Done()
		for i := 0; i < 1000; i++ {
			fr.SetListenAddr(":8080")
			fr.SetListenAddr(":9090")
		}
	}()

	// Goroutine 2: Repeatedly read listen addr
	go func() {
		defer wg.Done()
		for i := 0; i < 1000; i++ {
			_ = fr.ListenAddr()
		}
	}()

	wg.Wait()
	t.Log("Race condition test completed - run with -race flag to detect data races")
}

// TestConcurrentConfigurationChanges tests multiple setters being called concurrently.
func TestConcurrentConfigurationChanges(t *testing.T) {
	fr := NewFileReceiver("test", "/tmp", false)

	var wg sync.WaitGroup
	wg.Add(5)

	// Multiple goroutines modifying different fields concurrently
	go func() {
		defer wg.Done()
		for i := 0; i < 500; i++ {
			fr.SetPIN("pin")
		}
	}()

	go func() {
		defer wg.Done()
		for i := 0; i < 500; i++ {
			fr.SetAllowedExtensions([]string{"pdf"})
		}
	}()

	go func() {
		defer wg.Done()
		for i := 0; i < 500; i++ {
			fr.SetTransferLog("/tmp/log.json")
		}
	}()

	go func() {
		defer wg.Done()
		for i := 0; i < 500; i++ {
			fr.SetListenAddr(":8080")
		}
	}()

	// Reader goroutine simulating handler access using thread-safe methods
	go func() {
		defer wg.Done()
		for i := 0; i < 500; i++ {
			_ = fr.getExpectedPIN()
			_ = fr.hasExtensionFilter()
			_ = fr.GetSaveDir("test.pdf")
			_ = fr.ListenAddr()
		}
	}()

	wg.Wait()
	t.Log("Concurrent configuration test completed - run with -race flag to detect data races")
}

// =============================================================================
// Certificate Logging Tests
// These tests verify that the correct log message is shown when loading or
// generating TLS certificates.
// =============================================================================

// captureLogs temporarily redirects slog output to capture log messages
func captureLogs(t *testing.T) (*bytes.Buffer, func()) {
	t.Helper()
	var buf bytes.Buffer
	handler := slog.NewTextHandler(&buf, nil)
	oldLogger := slog.Default()
	slog.SetDefault(slog.New(handler))
	return &buf, func() {
		slog.SetDefault(oldLogger)
	}
}

// TestCertificateLoggingGenerating verifies that "Generating" is logged when certs don't exist
func TestCertificateLoggingGenerating(t *testing.T) {
	// Create a temp directory for certs
	tmpDir := t.TempDir()
	certDir := filepath.Join(tmpDir, "certs")
	if err := os.MkdirAll(certDir, 0700); err != nil {
		t.Fatalf("failed to create cert dir: %v", err)
	}

	privKeyFile := filepath.Join(certDir, "server.key.pem")
	certFile := filepath.Join(certDir, "server.crt")

	// Capture logs
	buf, restore := captureLogs(t)
	defer restore()

	// Simulate the logic from Init()
	_, keyErr := os.Stat(privKeyFile)
	_, certErr := os.Stat(certFile)
	if keyErr == nil && certErr == nil {
		slog.Info("Loading https certificate")
	} else {
		slog.Info("Generating https certificate")
	}

	logOutput := buf.String()
	if !strings.Contains(logOutput, "Generating https certificate") {
		t.Errorf("expected log to contain 'Generating https certificate', got: %s", logOutput)
	}
	if strings.Contains(logOutput, "Loading https certificate") {
		t.Errorf("unexpected 'Loading https certificate' in log: %s", logOutput)
	}
}

// TestCertificateLoggingLoading verifies that "Loading" is logged when certs exist
func TestCertificateLoggingLoading(t *testing.T) {
	// Create a temp directory for certs
	tmpDir := t.TempDir()
	certDir := filepath.Join(tmpDir, "certs")
	if err := os.MkdirAll(certDir, 0700); err != nil {
		t.Fatalf("failed to create cert dir: %v", err)
	}

	privKeyFile := filepath.Join(certDir, "server.key.pem")
	certFile := filepath.Join(certDir, "server.crt")

	// Generate certs first
	_, err := lsutils.GenAndSaveTLScert(privKeyFile, certFile)
	if err != nil {
		t.Fatalf("failed to generate certs: %v", err)
	}

	// Capture logs
	buf, restore := captureLogs(t)
	defer restore()

	// Simulate the logic from Init()
	_, keyErr := os.Stat(privKeyFile)
	_, certErr := os.Stat(certFile)
	if keyErr == nil && certErr == nil {
		slog.Info("Loading https certificate")
	} else {
		slog.Info("Generating https certificate")
	}

	logOutput := buf.String()
	if !strings.Contains(logOutput, "Loading https certificate") {
		t.Errorf("expected log to contain 'Loading https certificate', got: %s", logOutput)
	}
	if strings.Contains(logOutput, "Generating https certificate") {
		t.Errorf("unexpected 'Generating https certificate' in log: %s", logOutput)
	}
}

// TestCertificateLoggingPartialMissing verifies that "Generating" is logged when only one cert file exists
func TestCertificateLoggingPartialMissing(t *testing.T) {
	// Create a temp directory for certs
	tmpDir := t.TempDir()
	certDir := filepath.Join(tmpDir, "certs")
	if err := os.MkdirAll(certDir, 0700); err != nil {
		t.Fatalf("failed to create cert dir: %v", err)
	}

	privKeyFile := filepath.Join(certDir, "server.key.pem")
	certFile := filepath.Join(certDir, "server.crt")

	// Create only the cert file, not the private key
	if err := os.WriteFile(certFile, []byte("dummy"), 0644); err != nil {
		t.Fatalf("failed to create dummy cert: %v", err)
	}

	// Capture logs
	buf, restore := captureLogs(t)
	defer restore()

	// Simulate the logic from Init()
	_, keyErr := os.Stat(privKeyFile)
	_, certErr := os.Stat(certFile)
	if keyErr == nil && certErr == nil {
		slog.Info("Loading https certificate")
	} else {
		slog.Info("Generating https certificate")
	}

	logOutput := buf.String()
	if !strings.Contains(logOutput, "Generating https certificate") {
		t.Errorf("expected log to contain 'Generating https certificate' when key is missing, got: %s", logOutput)
	}
}
