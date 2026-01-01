package utils

import (
	"crypto/sha256"
	"encoding/hex"
	"io"
	"log/slog"
	"math/rand/v2"
	"net"
	"os"
	"os/signal"
	"strings"
	"sync"
	"syscall"
)

func WaitForSignal() chan os.Signal {
	ch := make(chan os.Signal, 1)
	signal.Notify(ch, os.Interrupt, syscall.SIGTERM, syscall.SIGHUP, syscall.SIGINT)

	return ch
}

func ForEachAsync[T any](arr []T, wg *sync.WaitGroup, do func(value T)) {
	for _, val := range arr {
		wg.Add(1)
		go func(val T) {
			defer wg.Done()

			do(val)
		}(val)
	}
}

func SHA256ofFile(fpath string) (string, error) {
	fd, err := os.Open(fpath)
	if err != nil {
		return "", err
	}
	defer func() { _ = fd.Close() }()

	hasher := sha256.New()
	_, err = io.Copy(hasher, fd)
	if err != nil {
		return "", err
	}

	return hex.EncodeToString(hasher.Sum(nil)), nil
}

// getMyIPv4Addr get ipv4 address of every RUNNING interfaces on the host
// Note: ipv6, loopback and non-private addressess are ignored
func GetMyIPv4Addr() ([]net.IP, error) {
	intfs, err := net.Interfaces()
	if err != nil {
		return nil, err
	}

	res := make([]net.IP, 0, len(intfs))

	for _, intf := range intfs {
		addrs, _ := intf.Addrs()
		for idx := range addrs {
			ip, _, _ := net.ParseCIDR(addrs[idx].String())
			if ip.To4() != nil && !ip.IsLoopback() && ip.IsPrivate() && (intf.Flags&net.FlagRunning != 0) {
				res = append(res, ip)
			}
		}
	}
	return res, nil
}

// RandChoice returns a random element from the slice.
// Uses math/rand/v2 which is automatically seeded with a cryptographically
// secure seed in Go 1.22+. Safe for non-cryptographic randomness.
func RandChoice[T any](l []T) T {
	if len(l) == 0 {
		var zero T
		return zero
	}
	randIndex := rand.IntN(len(l))

	return l[randIndex]
}

// GetProtocolScheme returns "https" or "http" based on the useHTTPS flag.
func GetProtocolScheme(useHTTPS bool) string {
	if useHTTPS {
		return "https"
	}
	return "http"
}

// ParseExtensionList parses a comma-separated list of file extensions,
// normalizes them to lowercase and trims whitespace.
// Returns nil if input is empty.
func ParseExtensionList(extString string) []string {
	if extString == "" {
		return nil
	}
	parts := strings.Split(extString, ",")
	result := make([]string, 0, len(parts))
	for _, ext := range parts {
		ext = strings.TrimSpace(strings.ToLower(ext))
		if ext != "" {
			result = append(result, ext)
		}
	}
	return result
}

// EnsureDirectory creates a directory if it doesn't exist.
// Returns nil if the directory already exists or was created successfully.
func EnsureDirectory(dir string) error {
	if err := os.MkdirAll(dir, 0o755); err != nil {
		slog.Error("Failed to create directory", "dir", dir, "error", err)
		return err
	}
	return nil
}
