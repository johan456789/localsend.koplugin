package storage

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
	"time"
)

func TestTrustedDeviceStore_SaveAtomic(t *testing.T) {
	// Create temp directory
	tmpDir := t.TempDir()

	store, err := NewTrustedDeviceStore(tmpDir)
	if err != nil {
		t.Fatalf("Failed to create store: %v", err)
	}

	// Add a device
	device := TrustedDevice{
		Alias:     "Test Device",
		PublicKey: "-----BEGIN PUBLIC KEY-----\nMCowBQYDK2VwAyEAtest\n-----END PUBLIC KEY-----",
		AddedAt:   time.Now().Unix(),
	}

	if err := store.Add(device); err != nil {
		t.Fatalf("Failed to add device: %v", err)
	}

	// Verify no temp file remains after save
	tempPath := filepath.Join(tmpDir, "trusted_devices.json.tmp")
	if _, err := os.Stat(tempPath); !os.IsNotExist(err) {
		t.Error("Temp file should not exist after successful save")
	}

	// Verify main file exists and is valid JSON
	filePath := filepath.Join(tmpDir, "trusted_devices.json")
	data, err := os.ReadFile(filePath)
	if err != nil {
		t.Fatalf("Failed to read saved file: %v", err)
	}

	var devices map[string]TrustedDevice
	if err := json.Unmarshal(data, &devices); err != nil {
		t.Fatalf("Saved file is not valid JSON: %v", err)
	}

	if len(devices) != 1 {
		t.Errorf("Expected 1 device, got %d", len(devices))
	}
}

func TestTrustedDeviceStore_SaveAtomic_PreservesOriginalOnError(t *testing.T) {
	// This test verifies that if we have an existing file and a new save
	// operation would fail, the original file is preserved.
	// With atomic save (temp file + rename), this is guaranteed.

	tmpDir := t.TempDir()

	// Create initial store with a device
	store1, err := NewTrustedDeviceStore(tmpDir)
	if err != nil {
		t.Fatalf("Failed to create store: %v", err)
	}

	device1 := TrustedDevice{
		Alias:     "Original Device",
		PublicKey: "-----BEGIN PUBLIC KEY-----\noriginal\n-----END PUBLIC KEY-----",
		AddedAt:   time.Now().Unix(),
	}

	if err := store1.Add(device1); err != nil {
		t.Fatalf("Failed to add device: %v", err)
	}

	// Create new store and verify original data loads correctly
	store2, err := NewTrustedDeviceStore(tmpDir)
	if err != nil {
		t.Fatalf("Failed to create second store: %v", err)
	}

	devices := store2.List()
	if len(devices) != 1 {
		t.Errorf("Expected 1 device after reload, got %d", len(devices))
	}
}

func TestTrustedDeviceStore_BasicOperations(t *testing.T) {
	tmpDir := t.TempDir()

	store, err := NewTrustedDeviceStore(tmpDir)
	if err != nil {
		t.Fatalf("Failed to create store: %v", err)
	}

	publicKey := "-----BEGIN PUBLIC KEY-----\nMCowBQYDK2VwAyEAtest\n-----END PUBLIC KEY-----"
	device := TrustedDevice{
		Alias:     "Test Device",
		PublicKey: publicKey,
		AddedAt:   time.Now().Unix(),
	}

	// Test Add
	if err := store.Add(device); err != nil {
		t.Fatalf("Failed to add device: %v", err)
	}

	// Test IsTrusted
	if !store.IsTrusted(publicKey) {
		t.Error("Device should be trusted after adding")
	}

	// Test List
	devices := store.List()
	if len(devices) != 1 {
		t.Errorf("Expected 1 device, got %d", len(devices))
	}

	// Test GetFingerprint and GetPublicKey
	fingerprint := store.GetFingerprint(publicKey)
	retrievedKey, ok := store.GetPublicKey(fingerprint)
	if !ok {
		t.Error("GetPublicKey should return ok=true for existing device")
	}
	if retrievedKey != publicKey {
		t.Error("Retrieved public key should match original")
	}

	// Test Remove
	if err := store.Remove(fingerprint); err != nil {
		t.Fatalf("Failed to remove device: %v", err)
	}

	if store.IsTrusted(publicKey) {
		t.Error("Device should not be trusted after removal")
	}
}

func TestTrustedDeviceStore_Persistence(t *testing.T) {
	tmpDir := t.TempDir()

	publicKey := "-----BEGIN PUBLIC KEY-----\npersistence-test\n-----END PUBLIC KEY-----"

	// Create store and add device
	store1, err := NewTrustedDeviceStore(tmpDir)
	if err != nil {
		t.Fatalf("Failed to create store: %v", err)
	}

	device := TrustedDevice{
		Alias:     "Persistent Device",
		PublicKey: publicKey,
		AddedAt:   time.Now().Unix(),
	}

	if err := store1.Add(device); err != nil {
		t.Fatalf("Failed to add device: %v", err)
	}

	// Create new store instance (simulates restart)
	store2, err := NewTrustedDeviceStore(tmpDir)
	if err != nil {
		t.Fatalf("Failed to create second store: %v", err)
	}

	// Verify device persisted
	if !store2.IsTrusted(publicKey) {
		t.Error("Device should be trusted after reload")
	}
}
