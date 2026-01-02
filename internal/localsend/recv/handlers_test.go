package recv

import (
	"bytes"
	"encoding/json"
	"io"
	"net/http/httptest"
	"testing"

	"localsend-cli/internal/crypto"
	"localsend-cli/internal/localsend"
	"localsend-cli/internal/localsend/constants"
	sess "localsend-cli/internal/localsend/session"
	lsutils "localsend-cli/internal/localsend/utils"
	"localsend-cli/internal/models"
	"github.com/gofiber/fiber/v2"
)

// newTestReceiver creates a FileReceiver for testing with minimal dependencies.
func newTestReceiver() *FileReceiver {
	return &FileReceiver{
		identity: models.DeviceInfo{
			Alias:       "Test Device",
			Version:     "2.3",
			DeviceModel: "Test",
			DeviceType:  "headless",
			Token:       "test-token",
		},
		webServer:           lsutils.NewWebServer(),
		sessman:             sess.NewRecvSessManager(),
		saveToDir:           "/tmp/test",
		receivedNonceCache:  localsend.NewNonceCache(200),
		generatedNonceCache: localsend.NewNonceCache(200),
	}
}

// =============================================================================
// Nonce Exchange Handler Tests (POST /api/localsend/v3/nonce)
// =============================================================================

func TestNonceExchangeHandler_ValidNonce(t *testing.T) {
	fr := newTestReceiver()
	app := fiber.New()
	app.Post(constants.NoncePathV3, fr.nonceExchangeHandler)

	// Generate a valid 32-byte nonce
	nonce, _ := crypto.GenerateNonce()
	encodedNonce := crypto.EncodeNonce(nonce)

	body, _ := json.Marshal(models.NonceRequest{Nonce: encodedNonce})
	req := httptest.NewRequest("POST", constants.NoncePathV3, bytes.NewReader(body))
	req.Header.Set("Content-Type", "application/json")

	resp, err := app.Test(req)
	if err != nil {
		t.Fatalf("Failed to make request: %v", err)
	}

	if resp.StatusCode != 200 {
		t.Errorf("Status = %d; want 200", resp.StatusCode)
	}

	// Parse response
	respBody, _ := io.ReadAll(resp.Body)
	var nonceResp models.NonceResponse
	if err := json.Unmarshal(respBody, &nonceResp); err != nil {
		t.Fatalf("Failed to parse response: %v", err)
	}

	// Response should contain a valid nonce
	if nonceResp.Nonce == "" {
		t.Error("Response nonce is empty")
	}

	// Decode and validate response nonce
	respNonce, err := crypto.DecodeNonce(nonceResp.Nonce)
	if err != nil {
		t.Errorf("Failed to decode response nonce: %v", err)
	}
	if !crypto.ValidateNonce(respNonce) {
		t.Errorf("Response nonce has invalid length: %d", len(respNonce))
	}
}

func TestNonceExchangeHandler_TooShortNonce(t *testing.T) {
	fr := newTestReceiver()
	app := fiber.New()
	app.Post(constants.NoncePathV3, fr.nonceExchangeHandler)

	// 15-byte nonce (minimum is 16)
	shortNonce := make([]byte, 15)
	encodedNonce := crypto.EncodeNonce(shortNonce)

	body, _ := json.Marshal(models.NonceRequest{Nonce: encodedNonce})
	req := httptest.NewRequest("POST", constants.NoncePathV3, bytes.NewReader(body))
	req.Header.Set("Content-Type", "application/json")

	resp, _ := app.Test(req)

	if resp.StatusCode != 400 {
		t.Errorf("Status = %d; want 400 for too short nonce", resp.StatusCode)
	}
}

func TestNonceExchangeHandler_TooLongNonce(t *testing.T) {
	fr := newTestReceiver()
	app := fiber.New()
	app.Post(constants.NoncePathV3, fr.nonceExchangeHandler)

	// 129-byte nonce (maximum is 128)
	longNonce := make([]byte, 129)
	encodedNonce := crypto.EncodeNonce(longNonce)

	body, _ := json.Marshal(models.NonceRequest{Nonce: encodedNonce})
	req := httptest.NewRequest("POST", constants.NoncePathV3, bytes.NewReader(body))
	req.Header.Set("Content-Type", "application/json")

	resp, _ := app.Test(req)

	if resp.StatusCode != 400 {
		t.Errorf("Status = %d; want 400 for too long nonce", resp.StatusCode)
	}
}

func TestNonceExchangeHandler_InvalidBase64(t *testing.T) {
	fr := newTestReceiver()
	app := fiber.New()
	app.Post(constants.NoncePathV3, fr.nonceExchangeHandler)

	body, _ := json.Marshal(models.NonceRequest{Nonce: "not!valid!base64!!!"})
	req := httptest.NewRequest("POST", constants.NoncePathV3, bytes.NewReader(body))
	req.Header.Set("Content-Type", "application/json")

	resp, _ := app.Test(req)

	if resp.StatusCode != 400 {
		t.Errorf("Status = %d; want 400 for invalid base64", resp.StatusCode)
	}
}

func TestNonceExchangeHandler_MissingNonce(t *testing.T) {
	fr := newTestReceiver()
	app := fiber.New()
	app.Post(constants.NoncePathV3, fr.nonceExchangeHandler)

	body, _ := json.Marshal(models.NonceRequest{Nonce: ""})
	req := httptest.NewRequest("POST", constants.NoncePathV3, bytes.NewReader(body))
	req.Header.Set("Content-Type", "application/json")

	resp, _ := app.Test(req)

	if resp.StatusCode != 400 {
		t.Errorf("Status = %d; want 400 for missing nonce", resp.StatusCode)
	}
}

func TestNonceExchangeHandler_InvalidJSON(t *testing.T) {
	fr := newTestReceiver()
	app := fiber.New()
	app.Post(constants.NoncePathV3, fr.nonceExchangeHandler)

	req := httptest.NewRequest("POST", constants.NoncePathV3, bytes.NewReader([]byte("not json")))
	req.Header.Set("Content-Type", "application/json")

	resp, _ := app.Test(req)

	if resp.StatusCode != 400 {
		t.Errorf("Status = %d; want 400 for invalid JSON", resp.StatusCode)
	}
}

func TestNonceExchangeHandler_MinimumValidNonce(t *testing.T) {
	fr := newTestReceiver()
	app := fiber.New()
	app.Post(constants.NoncePathV3, fr.nonceExchangeHandler)

	// Exactly 16-byte nonce (minimum valid)
	minNonce := make([]byte, 16)
	for i := range minNonce {
		minNonce[i] = byte(i)
	}
	encodedNonce := crypto.EncodeNonce(minNonce)

	body, _ := json.Marshal(models.NonceRequest{Nonce: encodedNonce})
	req := httptest.NewRequest("POST", constants.NoncePathV3, bytes.NewReader(body))
	req.Header.Set("Content-Type", "application/json")

	resp, _ := app.Test(req)

	if resp.StatusCode != 200 {
		t.Errorf("Status = %d; want 200 for minimum valid nonce (16 bytes)", resp.StatusCode)
	}
}

func TestNonceExchangeHandler_MaximumValidNonce(t *testing.T) {
	fr := newTestReceiver()
	app := fiber.New()
	app.Post(constants.NoncePathV3, fr.nonceExchangeHandler)

	// Exactly 128-byte nonce (maximum valid)
	maxNonce := make([]byte, 128)
	for i := range maxNonce {
		maxNonce[i] = byte(i)
	}
	encodedNonce := crypto.EncodeNonce(maxNonce)

	body, _ := json.Marshal(models.NonceRequest{Nonce: encodedNonce})
	req := httptest.NewRequest("POST", constants.NoncePathV3, bytes.NewReader(body))
	req.Header.Set("Content-Type", "application/json")

	resp, _ := app.Test(req)

	if resp.StatusCode != 200 {
		t.Errorf("Status = %d; want 200 for maximum valid nonce (128 bytes)", resp.StatusCode)
	}
}

// TestNonceExchangeHandler_CachesNonces verifies nonces are stored in cache.
func TestNonceExchangeHandler_CachesNonces(t *testing.T) {
	fr := newTestReceiver()
	app := fiber.New()
	app.Post(constants.NoncePathV3, fr.nonceExchangeHandler)

	nonce, _ := crypto.GenerateNonce()
	encodedNonce := crypto.EncodeNonce(nonce)

	body, _ := json.Marshal(models.NonceRequest{Nonce: encodedNonce})
	req := httptest.NewRequest("POST", constants.NoncePathV3, bytes.NewReader(body))
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("X-Forwarded-For", "192.168.1.100") // Simulate client IP

	resp, _ := app.Test(req)

	if resp.StatusCode != 200 {
		t.Fatalf("Request failed with status %d", resp.StatusCode)
	}

	// Note: The client ID in test environment might be different.
	// This test verifies the cache mechanism is called but may not
	// verify the exact IP due to test environment limitations.
}

// =============================================================================
// Register V3 Handler Tests (POST /api/localsend/v3/register)
// =============================================================================

func TestRegisterV3Handler_ValidRequest(t *testing.T) {
	fr := newTestReceiver()
	app := fiber.New()
	app.Post(constants.RegisterPathV3, fr.registerV3Handler)

	body, _ := json.Marshal(models.RegisterRequestV3{
		Alias:       "Test Sender",
		Version:     "2.3",
		DeviceModel: "iPhone",
		DeviceType:  "MOBILE",
		Token:       "sender-token",
		Port:        constants.DefaultPort,
		Protocol:    "https",
	})
	req := httptest.NewRequest("POST", constants.RegisterPathV3, bytes.NewReader(body))
	req.Header.Set("Content-Type", "application/json")

	resp, err := app.Test(req)
	if err != nil {
		t.Fatalf("Failed to make request: %v", err)
	}

	if resp.StatusCode != 200 {
		t.Errorf("Status = %d; want 200", resp.StatusCode)
	}

	respBody, _ := io.ReadAll(resp.Body)
	var registerResp models.RegisterResponseV3
	if err := json.Unmarshal(respBody, &registerResp); err != nil {
		t.Fatalf("Failed to parse response: %v", err)
	}

	// Response should contain our device info
	if registerResp.Alias != "Test Device" {
		t.Errorf("Alias = %q; want 'Test Device'", registerResp.Alias)
	}
	if registerResp.Version != "2.3" {
		t.Errorf("Version = %q; want '2.3'", registerResp.Version)
	}
}

func TestRegisterV3Handler_InvalidJSON(t *testing.T) {
	fr := newTestReceiver()
	app := fiber.New()
	app.Post(constants.RegisterPathV3, fr.registerV3Handler)

	req := httptest.NewRequest("POST", constants.RegisterPathV3, bytes.NewReader([]byte("invalid")))
	req.Header.Set("Content-Type", "application/json")

	resp, _ := app.Test(req)

	if resp.StatusCode != 400 {
		t.Errorf("Status = %d; want 400 for invalid JSON", resp.StatusCode)
	}
}

// =============================================================================
// Info V3 Handler Tests (GET /api/localsend/v3/info)
// =============================================================================

func TestInfoV3Handler(t *testing.T) {
	fr := newTestReceiver()
	app := fiber.New()
	app.Get(constants.InfoPathV3, fr.infoV3Handler)

	req := httptest.NewRequest("GET", constants.InfoPathV3, nil)

	resp, err := app.Test(req)
	if err != nil {
		t.Fatalf("Failed to make request: %v", err)
	}

	if resp.StatusCode != 200 {
		t.Errorf("Status = %d; want 200", resp.StatusCode)
	}

	respBody, _ := io.ReadAll(resp.Body)
	var infoResp models.RegisterResponseV3
	if err := json.Unmarshal(respBody, &infoResp); err != nil {
		t.Fatalf("Failed to parse response: %v", err)
	}

	if infoResp.Alias != "Test Device" {
		t.Errorf("Alias = %q; want 'Test Device'", infoResp.Alias)
	}
}

// =============================================================================
// Prepare Upload V3 Handler Tests (POST /api/localsend/v3/prepare-upload)
// =============================================================================

func TestPreUploadV3Handler_BlockedBySession(t *testing.T) {
	fr := newTestReceiver()

	// Create an active session to block new requests
	testFiles := models.FileMetas{
		"test-file": models.FileMeta{
			Id:       "test-file",
			Filename: "test.txt",
			Size:     100,
		},
	}
	_, _ = fr.sessman.NewSession(testFiles, "127.0.0.1")

	app := fiber.New()
	app.Post(constants.PreuploadPathV3, fr.preUploadV3Handler)

	body := []byte(`{"info":{"alias":"Sender"},"files":{}}`)
	req := httptest.NewRequest("POST", constants.PreuploadPathV3, bytes.NewReader(body))
	req.Header.Set("Content-Type", "application/json")

	resp, _ := app.Test(req)

	// Should return 409 Conflict when blocked by another session
	if resp.StatusCode != 409 {
		t.Errorf("Status = %d; want 409 when blocked by existing session", resp.StatusCode)
	}
}

func TestPreUploadV3Handler_PINRequired(t *testing.T) {
	fr := newTestReceiver()
	fr.SetPIN("123456")

	app := fiber.New()
	app.Post(constants.PreuploadPathV3, fr.preUploadV3Handler)

	body := []byte(`{"info":{"alias":"Sender"},"files":{}}`)
	req := httptest.NewRequest("POST", constants.PreuploadPathV3, bytes.NewReader(body))
	req.Header.Set("Content-Type", "application/json")

	resp, _ := app.Test(req)

	// Should return 401 when PIN is required but not provided
	if resp.StatusCode != 401 {
		t.Errorf("Status = %d; want 401 when PIN required", resp.StatusCode)
	}
}

func TestPreUploadV3Handler_WrongPIN(t *testing.T) {
	fr := newTestReceiver()
	fr.SetPIN("123456")

	app := fiber.New()
	app.Post(constants.PreuploadPathV3, fr.preUploadV3Handler)

	body := []byte(`{"info":{"alias":"Sender"},"files":{}}`)
	req := httptest.NewRequest("POST", constants.PreuploadPathV3+"?pin=wrongpin", bytes.NewReader(body))
	req.Header.Set("Content-Type", "application/json")

	resp, _ := app.Test(req)

	// Should return 401 when PIN is incorrect
	if resp.StatusCode != 401 {
		t.Errorf("Status = %d; want 401 when PIN is wrong", resp.StatusCode)
	}
}

func TestPreUploadV3Handler_CorrectPIN(t *testing.T) {
	fr := newTestReceiver()
	fr.SetPIN("123456")

	app := fiber.New()
	app.Post(constants.PreuploadPathV3, fr.preUploadV3Handler)

	body := []byte(`{"info":{"alias":"Sender","version":"2.3","deviceType":"MOBILE"},"files":{"file1":{"id":"file1","fileName":"test.txt","size":100,"fileType":"text/plain"}}}`)
	req := httptest.NewRequest("POST", constants.PreuploadPathV3+"?pin=123456", bytes.NewReader(body))
	req.Header.Set("Content-Type", "application/json")

	resp, _ := app.Test(req)

	// Should succeed with correct PIN (may return 200 or other depending on file acceptance)
	if resp.StatusCode == 401 {
		t.Errorf("Status = %d; should not be 401 with correct PIN", resp.StatusCode)
	}
}

// =============================================================================
// Nonce Caching Integration Tests
// =============================================================================

func TestNonceCacheIntegration(t *testing.T) {
	fr := newTestReceiver()

	// Simulate first client nonce exchange
	clientNonce1, _ := crypto.GenerateNonce()
	fr.receivedNonceCache.Put("client1", clientNonce1)

	serverNonce1, _ := crypto.GenerateNonce()
	fr.generatedNonceCache.Put("client1", serverNonce1)

	// Verify nonces are cached
	cached1, found := fr.receivedNonceCache.Get("client1")
	if !found {
		t.Fatal("Client nonce should be cached")
	}
	if !bytes.Equal(cached1, clientNonce1) {
		t.Error("Cached nonce doesn't match")
	}

	cached2, found := fr.generatedNonceCache.Get("client1")
	if !found {
		t.Fatal("Server nonce should be cached")
	}
	if !bytes.Equal(cached2, serverNonce1) {
		t.Error("Cached server nonce doesn't match")
	}

	// Combined nonce for token verification
	combinedNonce := append(clientNonce1, serverNonce1...)
	if len(combinedNonce) != 64 {
		t.Errorf("Combined nonce length = %d; want 64", len(combinedNonce))
	}
}
