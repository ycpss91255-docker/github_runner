package listener

import (
	"os"
	"path/filepath"
	"testing"
)

// writeExec drops an executable stub at a temp path and returns it, so the
// CommandDeviceDetector can be exercised against a scripted "device inventory"
// without any real hardware.
func writeExec(t *testing.T, body string) string {
	t.Helper()
	path := filepath.Join(t.TempDir(), "fake-detect")
	if err := os.WriteFile(path, []byte(body), 0o755); err != nil {
		t.Fatalf("write stub: %v", err)
	}
	return path
}

// The detector counts one device per non-empty output line, ignoring blank
// trailing lines (so `nvidia-smi -L`'s GPU-per-line output sizes the pool).
func TestCommandDeviceDetectorCountsLines(t *testing.T) {
	stub := writeExec(t, "#!/usr/bin/env bash\nprintf 'GPU 0\\nGPU 1\\nGPU 2\\n\\n'\n")
	d := CommandDeviceDetector{Name: stub, Args: []string{}}
	n, err := d.DetectDevices()
	if err != nil {
		t.Fatalf("DetectDevices error: %v", err)
	}
	if n != 3 {
		t.Errorf("counted %d devices, want 3", n)
	}
}

// A failing / absent enumeration command surfaces an error so the caller falls
// back to the default bound rather than treating it as zero devices.
func TestCommandDeviceDetectorErrorsWhenCommandFails(t *testing.T) {
	stub := writeExec(t, "#!/usr/bin/env bash\nexit 1\n")
	d := CommandDeviceDetector{Name: stub}
	if _, err := d.DetectDevices(); err == nil {
		t.Fatal("expected an error when the enumeration command exits non-zero")
	}
}

// No devices (empty output) reports a zero count with no error; resolveBound
// then treats zero as "fall back to the default".
func TestCommandDeviceDetectorZeroOnEmptyOutput(t *testing.T) {
	stub := writeExec(t, "#!/usr/bin/env bash\nprintf ''\n")
	d := CommandDeviceDetector{Name: stub}
	n, err := d.DetectDevices()
	if err != nil {
		t.Fatalf("DetectDevices error: %v", err)
	}
	if n != 0 {
		t.Errorf("counted %d, want 0 on empty output", n)
	}
}
