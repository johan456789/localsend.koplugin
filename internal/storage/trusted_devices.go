package storage

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"os"
	"path/filepath"
	"sync"
)

// TrustedDevice represents a device that has been paired and trusted.
type TrustedDevice struct {
	Alias     string `json:"alias"`
	PublicKey string `json:"publicKey"` // PEM-encoded Ed25519 public key
	AddedAt   int64  `json:"addedAt"`   // Unix timestamp
}

// TrustedDeviceStore manages the storage of trusted devices.
type TrustedDeviceStore struct {
	configDir string
	devices   map[string]TrustedDevice // keyed by fingerprint
	mu        sync.RWMutex
}

// NewTrustedDeviceStore creates a new store and loads existing devices from trusted_devices.json.
func NewTrustedDeviceStore(configDir string) (*TrustedDeviceStore, error) {
	store := &TrustedDeviceStore{
		configDir: configDir,
		devices:   make(map[string]TrustedDevice),
	}

	if err := store.load(); err != nil {
		return nil, err
	}

	return store, nil
}

// Add adds a device to the store and saves it to disk.
func (s *TrustedDeviceStore) Add(device TrustedDevice) error {
	s.mu.Lock()
	defer s.mu.Unlock()

	fingerprint := s.GetFingerprint(device.PublicKey)
	s.devices[fingerprint] = device

	return s.save()
}

// Remove removes a device from the store by its fingerprint.
func (s *TrustedDeviceStore) Remove(fingerprint string) error {
	s.mu.Lock()
	defer s.mu.Unlock()

	delete(s.devices, fingerprint)

	return s.save()
}

// IsTrusted checks if a public key is in the trusted devices list.
func (s *TrustedDeviceStore) IsTrusted(publicKey string) bool {
	s.mu.RLock()
	defer s.mu.RUnlock()

	fingerprint := s.GetFingerprint(publicKey)
	_, ok := s.devices[fingerprint]
	return ok
}

// GetPublicKey retrieves the public key for a given fingerprint.
func (s *TrustedDeviceStore) GetPublicKey(fingerprint string) (string, bool) {
	s.mu.RLock()
	defer s.mu.RUnlock()

	device, ok := s.devices[fingerprint]
	if !ok {
		return "", false
	}
	return device.PublicKey, true
}

// List returns a list of all trusted devices.
func (s *TrustedDeviceStore) List() []TrustedDevice {
	s.mu.RLock()
	defer s.mu.RUnlock()

	list := make([]TrustedDevice, 0, len(s.devices))
	for _, device := range s.devices {
		list = append(list, device)
	}
	return list
}

// GetFingerprint computes the SHA256 fingerprint of a public key.
func (s *TrustedDeviceStore) GetFingerprint(publicKey string) string {
	hash := sha256.Sum256([]byte(publicKey))
	return hex.EncodeToString(hash[:])
}

func (s *TrustedDeviceStore) load() error {
	filePath := filepath.Join(s.configDir, "trusted_devices.json")
	file, err := os.Open(filePath)
	if err != nil {
		if os.IsNotExist(err) {
			return nil
		}
		return err
	}
	defer func() { _ = file.Close() }()

	return json.NewDecoder(file).Decode(&s.devices)
}

func (s *TrustedDeviceStore) save() error {
	if err := os.MkdirAll(s.configDir, 0755); err != nil {
		return err
	}

	filePath := filepath.Join(s.configDir, "trusted_devices.json")
	file, err := os.Create(filePath)
	if err != nil {
		return err
	}
	defer func() { _ = file.Close() }()

	encoder := json.NewEncoder(file)
	encoder.SetIndent("", "  ")
	return encoder.Encode(s.devices)
}
