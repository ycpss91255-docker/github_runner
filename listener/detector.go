package listener

import (
	"context"
	"os/exec"
	"strings"
	"time"
)

// CommandDeviceDetector is the production DeviceDetector (#103): it counts host
// devices by running a small enumeration command and counting its non-empty
// output lines. The default command lists NVIDIA GPUs (`nvidia-smi -L`, one
// line per GPU), so a device runner auto-sizes its worker pool to the number of
// GPUs present. The command is configurable so other accelerators / inventories
// can be plugged in without touching the listener.
//
// This stays a thin shell-out (ADR-0003: host inspection is bash's job, Go only
// holds the resulting number for the pool brain). On any failure -- the command
// is absent, errors, or prints nothing -- DetectDevices returns an error and
// the caller falls back to defaultPoolBound, so a host without the tool still
// runs (with the conservative default) rather than refusing all work.
type CommandDeviceDetector struct {
	// Name is the enumeration command; defaults to "nvidia-smi".
	Name string
	// Args are its arguments; default lists one line per GPU.
	Args []string
	// Timeout bounds the detection call; defaults to 5s.
	Timeout time.Duration
}

// DetectDevices runs the enumeration command and returns the count of non-empty
// output lines (one device per line). It returns an error if the command is
// unavailable or fails, so the caller can fall back to the default bound.
func (d CommandDeviceDetector) DetectDevices() (int, error) {
	name := d.Name
	if name == "" {
		name = "nvidia-smi"
	}
	args := d.Args
	if args == nil {
		args = []string{"-L"}
	}
	timeout := d.Timeout
	if timeout <= 0 {
		timeout = 5 * time.Second
	}

	ctx, cancel := context.WithTimeout(context.Background(), timeout)
	defer cancel()

	out, err := exec.CommandContext(ctx, name, args...).Output()
	if err != nil {
		return 0, err
	}
	count := 0
	for _, line := range strings.Split(string(out), "\n") {
		if strings.TrimSpace(line) != "" {
			count++
		}
	}
	return count, nil
}
