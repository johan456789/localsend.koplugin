package storage

import (
	"os"
	"path/filepath"
	"testing"
	"time"
)

func TestNewTrustedDeviceStore(t *testing.T) {
	tempDir := t.TempDir()
	store, err := NewTrustedDeviceStore(tempDir)
	if err != nil {
		t.Fatalf("Failed to create store: %v", err)
	}
	if store == nil {
		t.Fatal("Store is nil")
	}
	if len(store.List()) != 0 {
		t.Errorf("Expected empty store, got %d devices", len(store.List()))
	}
}

func TestAddAndRetrieveDevice(t *testing.T) {
	tempDir := t.TempDir()
	store, err := NewTrustedDeviceStore(tempDir)
	if err != nil {
		t.Fatalf("Failed to create store: %v", err)
	}

	device := TrustedDevice{
		Alias:     "Test Device",
		PublicKey: "-----BEGIN PUBLIC KEY-----\nMCowBQYDK2VwAyEAtest123456789\n-----END PUBLIC KEY-----",
		AddedAt:   time.Now().Unix(),
	}

	if err := store.Add(device); err != nil {
		t.Fatalf("Failed to add device: %v", err)
	}

	// Check IsTrusted
	if !store.IsTrusted(device.PublicKey) {
		t.Error("Device should be trusted after adding")
	}

	// Check List
	devices := store.List()
	if len(devices) != 1 {
		t.Fatalf("Expected 1 device, got %d", len(devices))
	}
	if devices[0].Alias != "Test Device" {
		t.Errorf("Expected alias 'Test Device', got '%s'", devices[0].Alias)
	}

	// Check GetPublicKey
	fingerprint := store.GetFingerprint(device.PublicKey)
	pubKey, ok := store.GetPublicKey(fingerprint)
	if !ok {
		t.Error("Expected to find public key by fingerprint")
	}
	if pubKey != device.PublicKey {
		t.Errorf("Public key mismatch")
	}
}

func TestRemoveDevice(t *testing.T) {
	tempDir := t.TempDir()
	store, err := NewTrustedDeviceStore(tempDir)
	if err != nil {
		t.Fatalf("Failed to create store: %v", err)
	}

	device := TrustedDevice{
		Alias:     "Device to Remove",
		PublicKey: "-----BEGIN PUBLIC KEY-----\nremove-test-key\n-----END PUBLIC KEY-----",
		AddedAt:   time.Now().Unix(),
	}

	if err := store.Add(device); err != nil {
		t.Fatalf("Failed to add device: %v", err)
	}

	if !store.IsTrusted(device.PublicKey) {
		t.Fatal("Device should be trusted after adding")
	}

	fingerprint := store.GetFingerprint(device.PublicKey)
	if err := store.Remove(fingerprint); err != nil {
		t.Fatalf("Failed to remove device: %v", err)
	}

	if store.IsTrusted(device.PublicKey) {
		t.Error("Device should not be trusted after removal")
	}

	if len(store.List()) != 0 {
		t.Errorf("Expected empty store after removal, got %d devices", len(store.List()))
	}
}

func TestPersistence(t *testing.T) {
	tempDir := t.TempDir()

	// Create store and add device
	store1, err := NewTrustedDeviceStore(tempDir)
	if err != nil {
		t.Fatalf("Failed to create store: %v", err)
	}

	device := TrustedDevice{
		Alias:     "Persistent Device",
		PublicKey: "-----BEGIN PUBLIC KEY-----\npersistent-key\n-----END PUBLIC KEY-----",
		AddedAt:   time.Now().Unix(),
	}

	if err := store1.Add(device); err != nil {
		t.Fatalf("Failed to add device: %v", err)
	}

	// Verify file exists
	filePath := filepath.Join(tempDir, "trusted_devices.json")
	if _, err := os.Stat(filePath); os.IsNotExist(err) {
		t.Error("trusted_devices.json was not created")
	}

	// Create new store instance from same directory
	store2, err := NewTrustedDeviceStore(tempDir)
	if err != nil {
		t.Fatalf("Failed to create second store: %v", err)
	}

	// Verify device persisted
	if !store2.IsTrusted(device.PublicKey) {
		t.Error("Device should be trusted in reloaded store")
	}

	devices := store2.List()
	if len(devices) != 1 {
		t.Fatalf("Expected 1 device in reloaded store, got %d", len(devices))
	}
	if devices[0].Alias != "Persistent Device" {
		t.Errorf("Expected alias 'Persistent Device', got '%s'", devices[0].Alias)
	}
}

func TestIsTrustedNonExistent(t *testing.T) {
	tempDir := t.TempDir()
	store, err := NewTrustedDeviceStore(tempDir)
	if err != nil {
		t.Fatalf("Failed to create store: %v", err)
	}

	if store.IsTrusted("non-existent-key") {
		t.Error("Non-existent key should not be trusted")
	}
}

func TestGetFingerprintConsistency(t *testing.T) {
	tempDir := t.TempDir()
	store, _ := NewTrustedDeviceStore(tempDir)

	key := "test-public-key-123"
	fp1 := store.GetFingerprint(key)
	fp2 := store.GetFingerprint(key)

	if fp1 != fp2 {
		t.Errorf("Fingerprints should be consistent: %s != %s", fp1, fp2)
	}

	// Different keys should have different fingerprints
	fp3 := store.GetFingerprint("different-key")
	if fp1 == fp3 {
		t.Error("Different keys should have different fingerprints")
	}
}

func TestMultipleDevices(t *testing.T) {
	tempDir := t.TempDir()
	store, err := NewTrustedDeviceStore(tempDir)
	if err != nil {
		t.Fatalf("Failed to create store: %v", err)
	}

	devices := []TrustedDevice{
		{Alias: "Device 1", PublicKey: "key-1", AddedAt: time.Now().Unix()},
		{Alias: "Device 2", PublicKey: "key-2", AddedAt: time.Now().Unix()},
		{Alias: "Device 3", PublicKey: "key-3", AddedAt: time.Now().Unix()},
	}

	for _, d := range devices {
		if err := store.Add(d); err != nil {
			t.Fatalf("Failed to add device %s: %v", d.Alias, err)
		}
	}

	list := store.List()
	if len(list) != 3 {
		t.Errorf("Expected 3 devices, got %d", len(list))
	}

	for _, d := range devices {
		if !store.IsTrusted(d.PublicKey) {
			t.Errorf("Device %s should be trusted", d.Alias)
		}
	}

	// Remove middle device
	if err := store.Remove(store.GetFingerprint("key-2")); err != nil {
		t.Fatalf("Failed to remove device: %v", err)
	}

	if store.IsTrusted("key-2") {
		t.Error("Device 2 should not be trusted after removal")
	}
	if !store.IsTrusted("key-1") {
		t.Error("Device 1 should still be trusted")
	}
	if !store.IsTrusted("key-3") {
		t.Error("Device 3 should still be trusted")
	}
}
