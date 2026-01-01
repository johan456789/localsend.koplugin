package utils

import (
	"crypto/ed25519"
	"crypto/rand"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/pem"
	"math/big"
	"net"
	"net/http"
	"os"
	"time"

	"localsend-cli/internal/utils"
	"localsend-cli/templates"
	"github.com/gofiber/fiber/v2"
	"github.com/gofiber/template/html/v2"
	"github.com/google/uuid"
)

var aliasAdj = []string{
	"Adorable",
	"Beautiful",
	"Big",
	"Bright",
	"Clean",
	"Clever",
	"Cool",
	"Cute",
	"Cunning",
	"Determined",
	"Energetic",
	"Efficient",
	"Fantastic",
	"Fast",
	"Fine",
	"Fresh",
	"Good",
	"Gorgeous",
	"Great",
	"Handsome",
	"Hot",
	"Kind",
	"Lovely",
	"Mystic",
	"Neat",
	"Nice",
	"Patient",
	"Pretty",
	"Powerful",
	"Rich",
	"Secret",
	"Smart",
	"Solid",
	"Special",
	"Strategic",
	"Strong",
	"Tidy",
	"Wise",
}

var aliasFruit = []string{
	"Apple",
	"Avocado",
	"Banana",
	"Blackberry",
	"Blueberry",
	"Broccoli",
	"Carrot",
	"Cherry",
	"Coconut",
	"Grape",
	"Lemon",
	"Lettuce",
	"Mango",
	"Melon",
	"Mushroom",
	"Onion",
	"Orange",
	"Papaya",
	"Peach",
	"Pear",
	"Pineapple",
	"Potato",
	"Pumpkin",
	"Raspberry",
	"Strawberry",
	"Tomato",
}

// GenAndSaveTLScert generates an Ed25519 TLS certificate (per protocol spec v3:
// "Key Algorithm: RSA 2048 or Ed25519"). Ed25519 is preferred for constrained
// devices as it generates almost instantly compared to RSA.
func GenAndSaveTLScert(privKeyFile, certFile string) (tls.Certificate, error) {
	// Generate Ed25519 key pair - much faster than RSA on constrained devices
	pubkey, privkey, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		return tls.Certificate{}, err
	}

	template := x509.Certificate{
		SerialNumber: big.NewInt(1),
		Subject: pkix.Name{
			CommonName: "LocalSend User",
		},
		NotBefore:             time.Now(),
		NotAfter:              time.Now().AddDate(10, 0, 0), // 10 years per spec
		KeyUsage:              x509.KeyUsageDigitalSignature,
		ExtKeyUsage:           []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth, x509.ExtKeyUsageClientAuth},
		BasicConstraintsValid: true,
		IsCA:                  false,
		// SAN is required by modern TLS clients (iOS, etc.)
		DNSNames:    []string{"localhost", "localsend"},
		IPAddresses: []net.IP{net.ParseIP("127.0.0.1"), net.ParseIP("0.0.0.0")},
	}

	certBytes, err := x509.CreateCertificate(rand.Reader, &template, &template, pubkey, privkey)
	if err != nil {
		return tls.Certificate{}, err
	}

	// Marshal Ed25519 private key to PKCS8 format
	privBytes, err := x509.MarshalPKCS8PrivateKey(privkey)
	if err != nil {
		return tls.Certificate{}, err
	}

	certPrivKeyPem := pem.EncodeToMemory(&pem.Block{
		Type:  "PRIVATE KEY",
		Bytes: privBytes,
	})

	certPem := pem.EncodeToMemory(&pem.Block{
		Type:  "CERTIFICATE",
		Bytes: certBytes,
	})

	// save certificate
	err = os.WriteFile(certFile, certPem, 0o640)
	if err != nil {
		return tls.Certificate{}, err
	}

	// save private key
	err = os.WriteFile(privKeyFile, certPrivKeyPem, 0o640)
	if err != nil {
		return tls.Certificate{}, err
	}

	return tls.X509KeyPair(certPem, certPrivKeyPem)
}

func LoadOrGenTLScert(privKeyFile, certFile string) (tls.Certificate, error) {
	cert, err := tls.LoadX509KeyPair(certFile, privKeyFile)
	if err == nil {
		return cert, err
	}

	return GenAndSaveTLScert(privKeyFile, certFile)
}

func GenAlias() string {
	adj := utils.RandChoice(aliasAdj)
	fruit := utils.RandChoice(aliasFruit)

	return adj + " " + fruit
}

// GenFingerprint generates a random fingerprint for HTTP mode.
// In HTTPS mode, the fingerprint is derived from the TLS certificate instead.
func GenFingerprint() string {
	return uuid.NewString()
}

func NewWebServer(withTemplateEngine ...bool) *fiber.App {
	config := fiber.Config{
		Prefork:               false,
		DisableStartupMessage: true,
	//	BodyLimit:             100 * 1024 * 1024 * 1024, // 100G
		BodyLimit:             1 * 1024 * 1024 * 1024, // 1G (for 32-bit)
	}

	if len(withTemplateEngine) > 0 {
		if withTemplateEngine[0] {
			config.Views = html.NewFileSystem(http.FS(templates.TemplatesFS), ".html")
		}
	}

	return fiber.New(config)
}
