package recv

import (
	"sync"
	"testing"
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
