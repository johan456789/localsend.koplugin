package send

import (
	"io/fs"
	"path/filepath"

	"localsend-cli/internal/models"
)

type FileSender interface {
	SetPIN(pin string)
	Init(target *models.DeviceInfo, https bool) error
	AddFile(filePath string) error
	AddDir(dirPath string) error
	Start() error
	Cancel() error
}

type baseSender struct {
	tokens  models.FileTokens
	files   models.FileMetas
	session string
	pin     string
}

func (fsp *baseSender) SetPIN(pin string) {
	fsp.pin = pin
}

func (fsp *baseSender) AddFile(filePath string) error {
	if fsp.files == nil {
		fsp.files = make(map[string]models.FileMeta)
	}

	fileMeta, err := models.GenFileMeta(filePath)
	if err != nil {
		return err
	}

	fsp.files[fileMeta.Id] = fileMeta
	return nil
}

func (fsp *baseSender) AddDir(dirPath string) error {
	return filepath.Walk(dirPath, func(path string, info fs.FileInfo, err error) error {
		if err != nil {
			return err
		}

		if info.IsDir() {
			return nil
		}

		return fsp.AddFile(path)
	})
}

func (fsp *baseSender) reset() {
	// Use O(1) map reassignment instead of O(n) range-delete
	fsp.tokens = make(map[string]string)
	fsp.files = make(models.FileMetas)
}

// FileCount returns the number of files added to the sender.
func (fsp *baseSender) FileCount() int {
	return len(fsp.files)
}

// Files returns a copy of the files map for inspection.
func (fsp *baseSender) Files() models.FileMetas {
	return fsp.files
}
