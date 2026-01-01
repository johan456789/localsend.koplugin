package utils

import (
	"os"
	"path/filepath"
	"sync"
	"testing"
)

// TestRandChoice tests the RandChoice function
func TestRandChoice(t *testing.T) {
	t.Run("returns zero value for empty slice", func(t *testing.T) {
		var empty []int
		result := RandChoice(empty)
		if result != 0 {
			t.Errorf("expected 0 for empty int slice, got %d", result)
		}
	})

	t.Run("returns zero value for nil slice", func(t *testing.T) {
		var nilSlice []string
		result := RandChoice(nilSlice)
		if result != "" {
			t.Errorf("expected empty string for nil string slice, got %q", result)
		}
	})

	t.Run("returns the only element for single-element slice", func(t *testing.T) {
		single := []int{42}
		result := RandChoice(single)
		if result != 42 {
			t.Errorf("expected 42, got %d", result)
		}
	})

	t.Run("returns element from slice", func(t *testing.T) {
		items := []string{"a", "b", "c", "d", "e"}
		result := RandChoice(items)

		found := false
		for _, item := range items {
			if item == result {
				found = true
				break
			}
		}
		if !found {
			t.Errorf("result %q not found in original slice", result)
		}
	})

	t.Run("provides distribution across elements", func(t *testing.T) {
		items := []int{1, 2, 3}
		counts := make(map[int]int)

		// Run many iterations to check distribution
		iterations := 1000
		for i := 0; i < iterations; i++ {
			result := RandChoice(items)
			counts[result]++
		}

		// Each element should be picked at least once
		for _, item := range items {
			if counts[item] == 0 {
				t.Errorf("item %d was never selected in %d iterations", item, iterations)
			}
		}
	})
}

// TestSHA256ofFile tests the SHA256ofFile function
func TestSHA256ofFile(t *testing.T) {
	t.Run("computes correct hash for file", func(t *testing.T) {
		dir := t.TempDir()
		path := filepath.Join(dir, "test.txt")

		content := []byte("hello world")
		if err := os.WriteFile(path, content, 0644); err != nil {
			t.Fatalf("failed to create test file: %v", err)
		}

		hash, err := SHA256ofFile(path)
		if err != nil {
			t.Fatalf("SHA256ofFile failed: %v", err)
		}

		// SHA256("hello world") = b94d27b9934d3e08a52e52d7da7dabfac484efe37a5380ee9088f7ace2efcde9
		expected := "b94d27b9934d3e08a52e52d7da7dabfac484efe37a5380ee9088f7ace2efcde9"
		if hash != expected {
			t.Errorf("expected hash %s, got %s", expected, hash)
		}
	})

	t.Run("computes correct hash for empty file", func(t *testing.T) {
		dir := t.TempDir()
		path := filepath.Join(dir, "empty.txt")

		if err := os.WriteFile(path, []byte{}, 0644); err != nil {
			t.Fatalf("failed to create test file: %v", err)
		}

		hash, err := SHA256ofFile(path)
		if err != nil {
			t.Fatalf("SHA256ofFile failed: %v", err)
		}

		// SHA256("") = e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855
		expected := "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
		if hash != expected {
			t.Errorf("expected hash %s, got %s", expected, hash)
		}
	})

	t.Run("returns error for non-existent file", func(t *testing.T) {
		_, err := SHA256ofFile("/nonexistent/file.txt")
		if err == nil {
			t.Error("expected error for non-existent file")
		}
	})
}

// TestGetMyIPv4Addr tests the GetMyIPv4Addr function
func TestGetMyIPv4Addr(t *testing.T) {
	t.Run("returns valid IPs without error", func(t *testing.T) {
		ips, err := GetMyIPv4Addr()
		if err != nil {
			t.Fatalf("GetMyIPv4Addr failed: %v", err)
		}

		// Result might be empty if no private IPv4 interfaces are running
		// but it shouldn't error
		for _, ip := range ips {
			if ip.To4() == nil {
				t.Errorf("expected IPv4 address, got %v", ip)
			}
			if ip.IsLoopback() {
				t.Errorf("loopback addresses should be filtered out: %v", ip)
			}
			if !ip.IsPrivate() {
				t.Errorf("non-private addresses should be filtered out: %v", ip)
			}
		}
	})
}

// TestGetProtocolScheme tests the GetProtocolScheme function
func TestGetProtocolScheme(t *testing.T) {
	t.Run("returns https when useHTTPS is true", func(t *testing.T) {
		result := GetProtocolScheme(true)
		if result != "https" {
			t.Errorf("expected 'https', got %q", result)
		}
	})

	t.Run("returns http when useHTTPS is false", func(t *testing.T) {
		result := GetProtocolScheme(false)
		if result != "http" {
			t.Errorf("expected 'http', got %q", result)
		}
	})
}

// TestParseExtensionList tests the ParseExtensionList function
func TestParseExtensionList(t *testing.T) {
	t.Run("returns nil for empty string", func(t *testing.T) {
		result := ParseExtensionList("")
		if result != nil {
			t.Errorf("expected nil, got %v", result)
		}
	})

	t.Run("parses single extension", func(t *testing.T) {
		result := ParseExtensionList("pdf")
		if len(result) != 1 || result[0] != "pdf" {
			t.Errorf("expected [pdf], got %v", result)
		}
	})

	t.Run("parses multiple extensions", func(t *testing.T) {
		result := ParseExtensionList("pdf,epub,mobi")
		expected := []string{"pdf", "epub", "mobi"}
		if len(result) != len(expected) {
			t.Errorf("expected %v, got %v", expected, result)
		}
		for i, ext := range expected {
			if result[i] != ext {
				t.Errorf("expected %s at index %d, got %s", ext, i, result[i])
			}
		}
	})

	t.Run("trims whitespace", func(t *testing.T) {
		result := ParseExtensionList("  pdf , epub  ,  mobi  ")
		expected := []string{"pdf", "epub", "mobi"}
		if len(result) != len(expected) {
			t.Errorf("expected %v, got %v", expected, result)
		}
		for i, ext := range expected {
			if result[i] != ext {
				t.Errorf("expected %s at index %d, got %s", ext, i, result[i])
			}
		}
	})

	t.Run("converts to lowercase", func(t *testing.T) {
		result := ParseExtensionList("PDF,EPUB,Mobi")
		expected := []string{"pdf", "epub", "mobi"}
		if len(result) != len(expected) {
			t.Errorf("expected %v, got %v", expected, result)
		}
		for i, ext := range expected {
			if result[i] != ext {
				t.Errorf("expected %s at index %d, got %s", ext, i, result[i])
			}
		}
	})

	t.Run("filters empty entries", func(t *testing.T) {
		result := ParseExtensionList("pdf,,epub,  ,mobi")
		expected := []string{"pdf", "epub", "mobi"}
		if len(result) != len(expected) {
			t.Errorf("expected %v, got %v", expected, result)
		}
	})
}

// TestEnsureDirectory tests the EnsureDirectory function
func TestEnsureDirectory(t *testing.T) {
	t.Run("creates directory that doesn't exist", func(t *testing.T) {
		dir := t.TempDir()
		newDir := filepath.Join(dir, "new", "nested", "dir")

		err := EnsureDirectory(newDir)
		if err != nil {
			t.Fatalf("EnsureDirectory failed: %v", err)
		}

		info, err := os.Stat(newDir)
		if err != nil {
			t.Fatalf("directory was not created: %v", err)
		}
		if !info.IsDir() {
			t.Error("path is not a directory")
		}
	})

	t.Run("succeeds when directory already exists", func(t *testing.T) {
		dir := t.TempDir()

		// Call twice - should succeed both times
		err := EnsureDirectory(dir)
		if err != nil {
			t.Fatalf("EnsureDirectory failed on existing directory: %v", err)
		}
	})

	t.Run("returns error for invalid path", func(t *testing.T) {
		// Try to create a directory inside a file
		dir := t.TempDir()
		filePath := filepath.Join(dir, "file.txt")
		if err := os.WriteFile(filePath, []byte("content"), 0644); err != nil {
			t.Fatalf("failed to create test file: %v", err)
		}

		invalidDir := filepath.Join(filePath, "subdir")
		err := EnsureDirectory(invalidDir)
		if err == nil {
			t.Error("expected error when creating directory inside a file")
		}
	})
}

// TestForEachAsync tests the ForEachAsync function
func TestForEachAsync(t *testing.T) {
	t.Run("executes function for each element", func(t *testing.T) {
		items := []int{1, 2, 3, 4, 5}
		results := make(chan int, len(items))

		var wg sync.WaitGroup
		ForEachAsync(items, &wg, func(val int) {
			results <- val
		})
		wg.Wait()
		close(results)

		collected := make(map[int]bool)
		for val := range results {
			collected[val] = true
		}

		for _, item := range items {
			if !collected[item] {
				t.Errorf("item %d was not processed", item)
			}
		}
	})

	t.Run("handles empty slice", func(t *testing.T) {
		var empty []string
		var wg sync.WaitGroup

		ForEachAsync(empty, &wg, func(val string) {
			t.Error("function should not be called for empty slice")
		})
		wg.Wait()
	})
}
