package recv

import (
	"testing"
	"time"
)

// TestFileReceiver_cleanupExpiredPINAttempts_RemovesExpiredBlocks verifies that
// blocked IPs with expired blocks are removed during cleanup.
func TestFileReceiver_cleanupExpiredPINAttempts_RemovesExpiredBlocks(t *testing.T) {
	fr := NewFileReceiver("test", t.TempDir(), false)

	// Create a blocked IP with an old blockedAt time
	fr.pinAttempts = make(map[string]*pinAttemptInfo)
	fr.pinAttempts["192.168.1.1"] = &pinAttemptInfo{
		count:       maxPINAttempts,
		blockedAt:   time.Now().Add(-pinBlockDuration - time.Minute),
		lastAttempt: time.Now().Add(-pinBlockDuration - time.Minute),
	}

	// Run cleanup
	fr.cleanupExpiredPINAttempts()

	// Verify the entry was removed
	fr.configMu.Lock()
	_, exists := fr.pinAttempts["192.168.1.1"]
	fr.configMu.Unlock()

	if exists {
		t.Error("Expired blocked IP should have been removed")
	}
}

// TestFileReceiver_cleanupExpiredPINAttempts_RemovesStalePartialAttempts verifies that
// partial attempts (not yet blocked) with old lastAttempt are removed.
func TestFileReceiver_cleanupExpiredPINAttempts_RemovesStalePartialAttempts(t *testing.T) {
	fr := NewFileReceiver("test", t.TempDir(), false)

	// Create a partial attempt (not blocked) with old lastAttempt
	fr.pinAttempts = make(map[string]*pinAttemptInfo)
	fr.pinAttempts["192.168.1.1"] = &pinAttemptInfo{
		count:       1, // Less than maxPINAttempts
		lastAttempt: time.Now().Add(-pinBlockDuration - time.Minute),
	}

	// Run cleanup
	fr.cleanupExpiredPINAttempts()

	// Verify the entry was removed
	fr.configMu.Lock()
	_, exists := fr.pinAttempts["192.168.1.1"]
	fr.configMu.Unlock()

	if exists {
		t.Error("Stale partial attempt should have been removed")
	}
}

// TestFileReceiver_cleanupExpiredPINAttempts_KeepsActiveEntries verifies that
// recent entries are NOT removed during cleanup.
func TestFileReceiver_cleanupExpiredPINAttempts_KeepsActiveEntries(t *testing.T) {
	fr := NewFileReceiver("test", t.TempDir(), false)

	fr.pinAttempts = make(map[string]*pinAttemptInfo)

	// Recent blocked IP (should be kept)
	fr.pinAttempts["192.168.1.1"] = &pinAttemptInfo{
		count:       maxPINAttempts,
		blockedAt:   time.Now(),
		lastAttempt: time.Now(),
	}

	// Recent partial attempt (should be kept)
	fr.pinAttempts["192.168.1.2"] = &pinAttemptInfo{
		count:       1,
		lastAttempt: time.Now(),
	}

	// Run cleanup
	fr.cleanupExpiredPINAttempts()

	// Verify both entries are still present
	fr.configMu.Lock()
	_, exists1 := fr.pinAttempts["192.168.1.1"]
	_, exists2 := fr.pinAttempts["192.168.1.2"]
	fr.configMu.Unlock()

	if !exists1 {
		t.Error("Recent blocked IP should NOT have been removed")
	}
	if !exists2 {
		t.Error("Recent partial attempt should NOT have been removed")
	}
}

// TestFileReceiver_cleanupExpiredPINAttempts_NilMapNoOp verifies that
// cleanup handles nil pinAttempts map gracefully (no panic).
func TestFileReceiver_cleanupExpiredPINAttempts_NilMapNoOp(t *testing.T) {
	fr := NewFileReceiver("test", t.TempDir(), false)

	// Ensure pinAttempts is nil
	fr.pinAttempts = nil

	// This should not panic
	fr.cleanupExpiredPINAttempts()

	// Verify map is still nil (not allocated)
	fr.configMu.Lock()
	isNil := fr.pinAttempts == nil
	fr.configMu.Unlock()

	if !isNil {
		t.Error("pinAttempts should remain nil")
	}
}

// TestFileReceiver_cleanupExpiredPINAttempts_MixedEntries verifies cleanup
// correctly handles a mix of expired and active entries.
func TestFileReceiver_cleanupExpiredPINAttempts_MixedEntries(t *testing.T) {
	fr := NewFileReceiver("test", t.TempDir(), false)

	fr.pinAttempts = make(map[string]*pinAttemptInfo)

	// Expired blocked (should be removed)
	fr.pinAttempts["expired-blocked"] = &pinAttemptInfo{
		count:       maxPINAttempts,
		blockedAt:   time.Now().Add(-pinBlockDuration - time.Minute),
		lastAttempt: time.Now().Add(-pinBlockDuration - time.Minute),
	}

	// Expired partial (should be removed)
	fr.pinAttempts["expired-partial"] = &pinAttemptInfo{
		count:       1,
		lastAttempt: time.Now().Add(-pinBlockDuration - time.Minute),
	}

	// Recent blocked (should be kept)
	fr.pinAttempts["recent-blocked"] = &pinAttemptInfo{
		count:       maxPINAttempts,
		blockedAt:   time.Now(),
		lastAttempt: time.Now(),
	}

	// Recent partial (should be kept)
	fr.pinAttempts["recent-partial"] = &pinAttemptInfo{
		count:       2,
		lastAttempt: time.Now(),
	}

	// Run cleanup
	fr.cleanupExpiredPINAttempts()

	// Verify results
	fr.configMu.Lock()
	_, expiredBlockedExists := fr.pinAttempts["expired-blocked"]
	_, expiredPartialExists := fr.pinAttempts["expired-partial"]
	_, recentBlockedExists := fr.pinAttempts["recent-blocked"]
	_, recentPartialExists := fr.pinAttempts["recent-partial"]
	total := len(fr.pinAttempts)
	fr.configMu.Unlock()

	if expiredBlockedExists {
		t.Error("Expired blocked entry should have been removed")
	}
	if expiredPartialExists {
		t.Error("Expired partial entry should have been removed")
	}
	if !recentBlockedExists {
		t.Error("Recent blocked entry should have been kept")
	}
	if !recentPartialExists {
		t.Error("Recent partial entry should have been kept")
	}
	if total != 2 {
		t.Errorf("Expected 2 remaining entries, got %d", total)
	}
}
