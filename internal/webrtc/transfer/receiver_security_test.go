package transfer

import (
	"hash"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"sync"
	"testing"
	"time"

	"localsend-cli/internal/localsend/session"
)

// makeHasherMap creates an empty hash map for testing
func makeHasherMap() map[string]hash.Hash {
	return make(map[string]hash.Hash)
}

// =============================================================================
// Path Traversal Security Tests
// These tests verify that the WebRTC receiver properly sanitizes filenames
// to prevent directory traversal attacks (e.g., "../../../etc/passwd").
//
// The HTTP receiver at internal/localsend/session/recv.go:173 properly
// sanitizes filenames with filepath.Base(). The WebRTC receiver should
// apply the same protection.
// =============================================================================

// TestPrepareFilesForReceive_PathTraversal tests that malicious filenames
// with path traversal sequences cannot write files outside the save directory.
func TestPrepareFilesForReceive_PathTraversal(t *testing.T) {
	// Create a temporary directory structure for testing
	tmpDir := t.TempDir()
	saveDir := filepath.Join(tmpDir, "downloads")
	if err := os.MkdirAll(saveDir, 0755); err != nil {
		t.Fatalf("Failed to create save dir: %v", err)
	}

	// Create a sensitive file that should NOT be overwritten
	sensitiveDir := filepath.Join(tmpDir, "sensitive")
	if err := os.MkdirAll(sensitiveDir, 0755); err != nil {
		t.Fatalf("Failed to create sensitive dir: %v", err)
	}
	sensitiveFile := filepath.Join(sensitiveDir, "secret.txt")
	if err := os.WriteFile(sensitiveFile, []byte("ORIGINAL_SECRET"), 0644); err != nil {
		t.Fatalf("Failed to create sensitive file: %v", err)
	}

	tests := []struct {
		name          string
		maliciousName string
		description   string
	}{
		{
			name:          "parent directory traversal",
			maliciousName: "../sensitive/secret.txt",
			description:   "Simple ../ prefix to escape save directory",
		},
		{
			name:          "deep traversal",
			maliciousName: "../../../etc/passwd",
			description:   "Multiple ../ to reach system directories",
		},
		{
			name:          "absolute path unix",
			maliciousName: "/tmp/malicious.txt",
			description:   "Absolute path on Unix systems",
		},
		{
			name:          "mixed traversal",
			maliciousName: "foo/../../../sensitive/secret.txt",
			description:   "Traversal hidden within normal path",
		},
		{
			name:          "encoded traversal",
			maliciousName: "..%2F..%2Fsensitive/secret.txt",
			description:   "URL-encoded traversal (should be handled by caller but test anyway)",
		},
		{
			name:          "backslash traversal windows",
			maliciousName: "..\\..\\sensitive\\secret.txt",
			description:   "Windows-style path separators (on Unix, backslashes are valid filename chars)",
		},
		{
			name:          "null byte injection",
			maliciousName: "safe.txt\x00../sensitive/secret.txt",
			description:   "Null byte to truncate path processing",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			// Create a receiver with the save directory
			receiver := &RTCReceiver{
				saveDir:     saveDir,
				fileTokens:  make(map[string]string),
				fileWriters: make(map[string]*os.File),
				filePaths:   make(map[string]string),
				fileHashers: makeHasherMap(),
				files: []RTCFileDto{
					{
						ID:       "malicious-file",
						FileName: tt.maliciousName,
						Size:     100,
						FileType: "text/plain",
					},
				},
			}

			// Call prepareFilesForReceive with the malicious file
			tokens := receiver.prepareFilesForReceive([]string{"malicious-file"})

			// If a file was created, verify it's inside the save directory
			if len(tokens) > 0 {
				createdPath := receiver.filePaths["malicious-file"]

				// Clean up the file
				if f, ok := receiver.fileWriters["malicious-file"]; ok {
					_ = f.Close()
				}

				// The created file MUST be inside saveDir
				// Use filepath.Abs and HasPrefix for accurate containment check
				absSaveDir, _ := filepath.Abs(saveDir)
				absCreatedPath, _ := filepath.Abs(createdPath)

				// Normalize both paths to catch traversal
				absSaveDir = filepath.Clean(absSaveDir) + string(filepath.Separator)
				absCreatedPath = filepath.Clean(absCreatedPath)

				if !strings.HasPrefix(absCreatedPath, absSaveDir) {
					t.Errorf("PATH TRAVERSAL VULNERABILITY: File created outside save directory!\n"+
						"  Malicious filename: %q\n"+
						"  Created at: %q\n"+
						"  Save directory: %q\n"+
						"  Description: %s",
						tt.maliciousName, createdPath, saveDir, tt.description)
				}

				// The filename should be sanitized to just the base name
				baseName := filepath.Base(createdPath)
				expectedBase := filepath.Base(tt.maliciousName)
				if baseName != expectedBase && !strings.Contains(baseName, expectedBase) {
					// This is actually fine - just means the sanitization worked
					t.Logf("Filename was sanitized: %q -> %q", tt.maliciousName, baseName)
				}

				// Clean up
				_ = os.Remove(createdPath)
			}

			// Verify the sensitive file was NOT modified
			content, err := os.ReadFile(sensitiveFile)
			if err != nil {
				t.Errorf("Sensitive file was deleted or became unreadable: %v", err)
			} else if string(content) != "ORIGINAL_SECRET" {
				t.Errorf("SECURITY BREACH: Sensitive file was modified!\n"+
					"  Expected content: ORIGINAL_SECRET\n"+
					"  Actual content: %s", string(content))
			}
		})
	}
}

// TestGetSaveDir_PathTraversal tests that getSaveDir doesn't allow
// traversal via extension routing.
func TestGetSaveDir_PathTraversal(t *testing.T) {
	tmpDir := t.TempDir()
	saveDir := filepath.Join(tmpDir, "downloads")

	receiver := &RTCReceiver{
		saveDir: saveDir,
		extRoutes: map[string]string{
			"pdf":  filepath.Join(tmpDir, "books"),
			"epub": filepath.Join(tmpDir, "ebooks"),
		},
	}

	tests := []struct {
		name     string
		filename string
	}{
		{"traversal in extension", "../../../.pdf"},
		{"traversal before extension", "../../../etc/passwd.pdf"},
		{"null byte before extension", "file\x00.pdf"},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			result := receiver.getSaveDir(tt.filename)

			// The result should always be one of our configured directories
			// and never escape the tmpDir
			relPath, err := filepath.Rel(tmpDir, result)
			if err != nil {
				t.Errorf("Failed to compute relative path: %v", err)
				return
			}

			if strings.HasPrefix(relPath, "..") {
				t.Errorf("getSaveDir allowed path traversal!\n"+
					"  Filename: %q\n"+
					"  Returned: %q\n"+
					"  Base dir: %q",
					tt.filename, result, tmpDir)
			}
		})
	}
}

// TestCreateUniqueFile_PathTraversal_CallerMustSanitize documents that CreateUniqueFile
// does NOT sanitize filenames - the caller (prepareFilesForReceive) is responsible.
// This test ensures we understand this API contract.
func TestCreateUniqueFile_PathTraversal_CallerMustSanitize(t *testing.T) {
	tmpDir := t.TempDir()
	saveDir := filepath.Join(tmpDir, "downloads")
	if err := os.MkdirAll(saveDir, 0755); err != nil {
		t.Fatalf("Failed to create save dir: %v", err)
	}

	// Create a sensitive file
	sensitiveDir := filepath.Join(tmpDir, "sensitive")
	if err := os.MkdirAll(sensitiveDir, 0755); err != nil {
		t.Fatalf("Failed to create sensitive dir: %v", err)
	}
	sensitiveFile := filepath.Join(sensitiveDir, "secret.txt")
	if err := os.WriteFile(sensitiveFile, []byte("ORIGINAL"), 0644); err != nil {
		t.Fatalf("Failed to create sensitive file: %v", err)
	}

	traversalFilenames := []string{
		"../sensitive/secret.txt",
		"../../sensitive/secret.txt",
		"foo/../../../sensitive/secret.txt",
	}

	for _, filename := range traversalFilenames {
		t.Run(filename, func(t *testing.T) {
			// NOTE: This test demonstrates the vulnerability in CreateUniqueFile
			// which does NOT sanitize the filename.
			// The caller (prepareFilesForReceive) should sanitize before calling.
			file, path, err := session.CreateUniqueFile(saveDir, filename)
			if err != nil {
				// Error is acceptable - means we couldn't create the file
				t.Logf("CreateUniqueFile returned error (acceptable): %v", err)
				return
			}
			defer func() {
				_ = file.Close()
				_ = os.Remove(path)
			}()

			// Check if the file was created outside saveDir
			relPath, err := filepath.Rel(saveDir, path)
			if err != nil {
				t.Errorf("Failed to compute relative path: %v", err)
				return
			}

			if strings.HasPrefix(relPath, "..") {
				// This is expected behavior - CreateUniqueFile does NOT sanitize.
				// The caller must sanitize. This test documents this API contract.
				t.Logf("CreateUniqueFile allows path traversal (by design - caller must sanitize):\n"+
					"  Filename: %q\n"+
					"  Created at: %q\n"+
					"  Save directory: %q\n"+
					"  NOTE: prepareFilesForReceive sanitizes with filepath.Base() before calling",
					filename, path, saveDir)
			}
		})
	}
}

// TestRTCReceiver_FilenameIsSanitized verifies that after the fix,
// filenames from the sender are properly sanitized.
func TestRTCReceiver_FilenameIsSanitized(t *testing.T) {
	tmpDir := t.TempDir()
	saveDir := filepath.Join(tmpDir, "downloads")
	if err := os.MkdirAll(saveDir, 0755); err != nil {
		t.Fatalf("Failed to create save dir: %v", err)
	}

	// Malicious filenames that should all result in files INSIDE saveDir
	testCases := []struct {
		input       string
		expected    string // Expected sanitized base name
		windowsOnly bool   // Skip on non-Windows platforms
	}{
		{"../../../etc/passwd", "passwd", false},
		{"..\\..\\..\\windows\\system32\\config\\sam", "sam", true}, // Backslash is path sep only on Windows
		{"/etc/shadow", "shadow", false},
		{"foo/../../../bar.txt", "bar.txt", false},
		{"normal.txt", "normal.txt", false},
		{"sub/dir/file.txt", "file.txt", false},
	}

	for _, tc := range testCases {
		t.Run(tc.input, func(t *testing.T) {
			// Skip Windows-specific tests on non-Windows platforms
			if tc.windowsOnly && runtime.GOOS != "windows" {
				t.Skipf("Skipping Windows-specific test on %s (backslash is not a path separator)", runtime.GOOS)
			}

			receiver := &RTCReceiver{
				saveDir:     saveDir,
				fileTokens:  make(map[string]string),
				fileWriters: make(map[string]*os.File),
				filePaths:   make(map[string]string),
				fileHashers: makeHasherMap(),
				files: []RTCFileDto{
					{
						ID:       "test-file",
						FileName: tc.input,
						Size:     100,
						FileType: "text/plain",
					},
				},
			}

			tokens := receiver.prepareFilesForReceive([]string{"test-file"})

			if len(tokens) > 0 {
				createdPath := receiver.filePaths["test-file"]

				// Clean up
				if f, ok := receiver.fileWriters["test-file"]; ok {
					_ = f.Close()
				}
				defer os.Remove(createdPath)

				// Verify the file is inside saveDir
				if !strings.HasPrefix(createdPath, saveDir) {
					t.Errorf("File created outside save directory: %s", createdPath)
				}

				// Verify the base name matches expected
				baseName := filepath.Base(createdPath)
				// Account for possible " (1)" suffix if file already exists
				if !strings.HasPrefix(baseName, strings.TrimSuffix(tc.expected, filepath.Ext(tc.expected))) {
					t.Errorf("Base name mismatch: got %q, want prefix %q",
						baseName, tc.expected)
				}
			}
		})
	}
}

// =============================================================================
// Concurrency/Race Condition Tests
// =============================================================================

// TestRTCReceiver_sendError_Race verifies that sendError() is thread-safe.
// sendError reads r.peer which can be modified by other goroutines.
func TestRTCReceiver_sendError_Race(t *testing.T) {
	r := &RTCReceiver{
		peer:        nil,
		fileTokens:  make(map[string]string),
		fileWriters: make(map[string]*os.File),
		filePaths:   make(map[string]string),
		fileHashers: makeHasherMap(),
	}

	var wg sync.WaitGroup
	const goroutines = 50

	// Concurrent sendError calls
	for i := 0; i < goroutines; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			r.sendError("test error")
		}()
	}

	// Concurrent peer modifications (simulating AcceptOffer and Close)
	for i := 0; i < goroutines; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			r.mu.Lock()
			r.peer = nil
			r.mu.Unlock()
		}()
	}

	wg.Wait()
}

// =============================================================================
// Deadlock Prevention Tests
// =============================================================================

// TestRTCReceiver_handleFileList_NoDeadlock verifies that the onSelectFiles
// callback can safely access receiver methods without causing a deadlock.
// Before the fix, handleFileList would call the callback while holding the mutex,
// and if the callback tried to call Close() or other methods, it would deadlock.
func TestRTCReceiver_handleFileList_NoDeadlock(t *testing.T) {
	tmpDir := t.TempDir()
	r := &RTCReceiver{
		saveDir:     tmpDir,
		fileTokens:  make(map[string]string),
		fileWriters: make(map[string]*os.File),
		filePaths:   make(map[string]string),
		fileHashers: makeHasherMap(),
		files: []RTCFileDto{
			{ID: "test-1", FileName: "test.txt", Size: 100},
		},
		state: stateWaitFileList,
	}

	// Set a callback that attempts to access the receiver
	// This would deadlock if the mutex is still held when callback is invoked
	callbackDone := make(chan struct{})
	r.OnSelectFiles(func(files []RTCFileDto) []string {
		// This tries to access the receiver - would deadlock if mutex held
		_ = r.saveDir // read access
		close(callbackDone)
		// Return file IDs to avoid nil peer panic in response path
		ids := make([]string, len(files))
		for i, f := range files {
			ids[i] = f.ID
		}
		return ids
	})

	// Simulate receiving a file list message
	// This will call handleMessage which acquires the mutex
	done := make(chan struct{})
	go func() {
		defer func() {
			recover() // Ignore panic from nil peer in later code paths
			close(done)
		}()
		data := []byte(`{"status":"OK","files":[{"id":"test-1","fileName":"test.txt","size":100}]}`)
		r.handleMessage(data)
	}()

	// Wait with timeout
	select {
	case <-done:
		// Success - no deadlock
	case <-callbackDone:
		// Callback executed, wait for handleMessage to complete
		<-done
	case <-time.After(2 * time.Second):
		t.Fatal("Deadlock detected: handleMessage did not complete within timeout")
	}
}

// TestRTCReceiver_CallbackCanAccessMethods tests that after the fix,
// callbacks can safely call receiver methods that acquire the mutex.
func TestRTCReceiver_CallbackCanAccessMethods(t *testing.T) {
	tmpDir := t.TempDir()
	r := &RTCReceiver{
		saveDir:     tmpDir,
		fileTokens:  make(map[string]string),
		fileWriters: make(map[string]*os.File),
		filePaths:   make(map[string]string),
		fileHashers: makeHasherMap(),
		files: []RTCFileDto{
			{ID: "test-1", FileName: "test.txt", Size: 100},
		},
		state: stateWaitFileList,
	}

	// This is the key test: callback calls a method that needs the mutex
	// sendError() acquires the mutex - this would deadlock before the fix
	callbackExecuted := false
	r.OnSelectFiles(func(files []RTCFileDto) []string {
		r.sendError("test from callback")
		callbackExecuted = true
		// Return all file IDs to avoid the "DECLINED" path which needs a peer
		ids := make([]string, len(files))
		for i, f := range files {
			ids[i] = f.ID
		}
		return ids
	})

	// Use a timeout to detect deadlock
	done := make(chan struct{})
	go func() {
		defer func() {
			recover() // Ignore panic from nil peer in later code paths
			close(done)
		}()
		data := []byte(`{"status":"OK","files":[{"id":"test-1","fileName":"test.txt","size":100}]}`)
		r.handleMessage(data)
	}()

	select {
	case <-done:
		if !callbackExecuted {
			t.Error("Callback was not executed")
		}
	case <-time.After(2 * time.Second):
		t.Fatal("Deadlock detected: handleMessage did not complete within timeout")
	}
}
