package listener

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// writeConfig drops a runner-types config at a temp path and returns it, so the
// loader can be exercised against on-disk YAML without a fixture checked in.
func writeConfig(t *testing.T, body string) string {
	t.Helper()
	path := filepath.Join(t.TempDir(), "runner-types.yaml")
	if err := os.WriteFile(path, []byte(body), 0o644); err != nil {
		t.Fatalf("write config: %v", err)
	}
	return path
}

// A valid config with every documented field loads into a typed []RunnerType,
// preserving labels, image, devices, runtime, build tool, hardening profile and
// the scale set, and defaulting concurrency to auto when unset.
func TestLoadConfigValid(t *testing.T) {
	path := writeConfig(t, `
runner_types:
  - name: gpu
    scale_set: gpu-runners
    labels: [self-hosted, gpu, cuda]
    image: ghcr.io/acme/gpu-runner@sha256:abc
    devices: [/dev/nvidia0, /dev/nvidiactl]
    runtime: nvidia
    build_tool: kaniko
    hardening_profile: device
    concurrency:
      mode: auto
`)
	types, err := LoadConfig(path)
	if err != nil {
		t.Fatalf("LoadConfig: %v", err)
	}
	if len(types) != 1 {
		t.Fatalf("got %d runner types, want 1", len(types))
	}
	rt := types[0]
	if rt.Name != "gpu" {
		t.Errorf("Name = %q, want gpu", rt.Name)
	}
	if rt.ScaleSet != "gpu-runners" {
		t.Errorf("ScaleSet = %q, want gpu-runners", rt.ScaleSet)
	}
	if got := strings.Join(rt.Labels, ","); got != "self-hosted,gpu,cuda" {
		t.Errorf("Labels = %q", got)
	}
	if rt.Image != "ghcr.io/acme/gpu-runner@sha256:abc" {
		t.Errorf("Image = %q", rt.Image)
	}
	if got := strings.Join(rt.Devices, ","); got != "/dev/nvidia0,/dev/nvidiactl" {
		t.Errorf("Devices = %q", got)
	}
	if rt.Runtime != "nvidia" {
		t.Errorf("Runtime = %q", rt.Runtime)
	}
	if rt.BuildTool != "kaniko" {
		t.Errorf("BuildTool = %q", rt.BuildTool)
	}
	if rt.HardeningProfile != "device" {
		t.Errorf("HardeningProfile = %q", rt.HardeningProfile)
	}
	if !rt.Concurrency.DeviceSized() {
		t.Errorf("mode: auto should be device-sized")
	}
}

// An omitted concurrency block defaults to reactive live-admission (ADR-0005):
// not device-sized, and Reserve unset (New applies the default headroom).
func TestLoadConfigConcurrencyDefaultsReactive(t *testing.T) {
	path := writeConfig(t, `
runner_types:
  - name: cpu
    scale_set: cpu-runners
    labels: [self-hosted, cpu]
    image: ghcr.io/actions/actions-runner@sha256:def
`)
	types, err := LoadConfig(path)
	if err != nil {
		t.Fatalf("LoadConfig: %v", err)
	}
	c := types[0].Concurrency
	if c.DeviceSized() {
		t.Errorf("omitted concurrency should be reactive, not device-sized")
	}
	if c.Reserve != 0 {
		t.Errorf("omitted reserve = %d, want 0 (New applies the default)", c.Reserve)
	}
}

// An explicit reserve is honoured and stays reactive (not device-sized).
func TestLoadConfigConcurrencyReserve(t *testing.T) {
	path := writeConfig(t, `
runner_types:
  - name: cpu
    scale_set: cpu-runners
    labels: [self-hosted, cpu]
    image: ghcr.io/actions/actions-runner@sha256:def
    concurrency:
      reserve: 20
`)
	types, err := LoadConfig(path)
	if err != nil {
		t.Fatalf("LoadConfig: %v", err)
	}
	c := types[0].Concurrency
	if c.DeviceSized() {
		t.Errorf("a reserve-only type should be reactive, not device-sized")
	}
	if c.Reserve != 20 {
		t.Errorf("Reserve = %d, want 20", c.Reserve)
	}
}

// Two distinct runner types load side by side from one file -- the basis for
// running multiple types without code changes (#112).
func TestLoadConfigTwoTypes(t *testing.T) {
	path := writeConfig(t, `
runner_types:
  - name: gpu
    scale_set: gpu-runners
    labels: [self-hosted, gpu]
    image: img-gpu@sha256:1
  - name: cpu
    scale_set: cpu-runners
    labels: [self-hosted, cpu]
    image: img-cpu@sha256:2
`)
	types, err := LoadConfig(path)
	if err != nil {
		t.Fatalf("LoadConfig: %v", err)
	}
	if len(types) != 2 {
		t.Fatalf("got %d types, want 2", len(types))
	}
	if types[0].Name != "gpu" || types[1].Name != "cpu" {
		t.Errorf("type order/names = %q, %q", types[0].Name, types[1].Name)
	}
}

func TestLoadConfigErrors(t *testing.T) {
	cases := []struct {
		name string
		body string
		want string // substring of the error
	}{
		{
			name: "missing name",
			body: "runner_types:\n  - scale_set: s\n    labels: [a]\n    image: i@sha256:1\n",
			want: "name",
		},
		{
			name: "missing scale_set",
			body: "runner_types:\n  - name: gpu\n    labels: [a]\n    image: i@sha256:1\n",
			want: "scale_set",
		},
		{
			name: "missing labels",
			body: "runner_types:\n  - name: gpu\n    scale_set: s\n    image: i@sha256:1\n",
			want: "labels",
		},
		{
			name: "missing image",
			body: "runner_types:\n  - name: gpu\n    scale_set: s\n    labels: [a]\n",
			want: "image",
		},
		{
			name: "empty types",
			body: "runner_types: []\n",
			want: "at least one",
		},
		{
			name: "duplicate name",
			body: "runner_types:\n  - name: gpu\n    scale_set: s1\n    labels: [a]\n    image: i@sha256:1\n  - name: gpu\n    scale_set: s2\n    labels: [b]\n    image: j@sha256:2\n",
			want: "duplicate",
		},
		{
			name: "duplicate scale_set",
			body: "runner_types:\n  - name: a\n    scale_set: s\n    labels: [a]\n    image: i@sha256:1\n  - name: b\n    scale_set: s\n    labels: [b]\n    image: j@sha256:2\n",
			want: "scale set",
		},
		{
			name: "removed fixed mode is rejected",
			body: "runner_types:\n  - name: gpu\n    scale_set: s\n    labels: [a]\n    image: i@sha256:1\n    concurrency:\n      mode: fixed\n      count: 4\n",
			want: "mode",
		},
		{
			name: "unknown concurrency mode",
			body: "runner_types:\n  - name: gpu\n    scale_set: s\n    labels: [a]\n    image: i@sha256:1\n    concurrency:\n      mode: bogus\n",
			want: "mode",
		},
		{
			name: "reserve below the upward-only minimum",
			body: "runner_types:\n  - name: cpu\n    scale_set: s\n    labels: [a]\n    image: i@sha256:1\n    concurrency:\n      reserve: 5\n",
			want: "reserve",
		},
		{
			name: "unknown build tool",
			body: "runner_types:\n  - name: gpu\n    scale_set: s\n    labels: [a]\n    image: i@sha256:1\n    build_tool: frobnicate\n",
			want: "build_tool",
		},
		{
			// A typo'd knob must be rejected loudly, not silently dropped:
			// "reserv" would otherwise decode into nothing, leaving Reserve at
			// its zero value, so the headroom the operator asked for vanishes
			// without a word. Configuration never fails silently.
			name: "unknown field is rejected",
			body: "runner_types:\n  - name: cpu\n    scale_set: s\n    labels: [a]\n    image: i@sha256:1\n    concurrency:\n      reserv: 99\n",
			want: "reserv",
		},
		{
			name: "malformed yaml",
			body: "runner_types: [: : :\n",
			want: "parse",
		},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			path := writeConfig(t, tc.body)
			_, err := LoadConfig(path)
			if err == nil {
				t.Fatalf("expected error containing %q, got nil", tc.want)
			}
			if !strings.Contains(err.Error(), tc.want) {
				t.Errorf("error %q does not contain %q", err.Error(), tc.want)
			}
		})
	}
}

// The build-tool selector (#119) accepts exactly the daemonless builders the
// build seam routes to -- kaniko, buildkit -- plus none/empty (no build). Each
// loads cleanly and round-trips into RunnerType.BuildTool so the listener can
// route build jobs to the correct seam.
func TestLoadConfigBuildToolSelection(t *testing.T) {
	for _, tool := range []string{"kaniko", "buildkit", "none", ""} {
		t.Run("tool="+tool, func(t *testing.T) {
			body := "runner_types:\n  - name: gpu\n    scale_set: s\n    labels: [a]\n    image: i@sha256:1\n"
			if tool != "" {
				body += "    build_tool: " + tool + "\n"
			}
			types, err := LoadConfig(writeConfig(t, body))
			if err != nil {
				t.Fatalf("build_tool %q should load, got %v", tool, err)
			}
			if types[0].BuildTool != tool {
				t.Errorf("BuildTool = %q, want %q", types[0].BuildTool, tool)
			}
		})
	}
}

// A missing config file is a clear, non-zero error (fail closed).
func TestLoadConfigMissingFile(t *testing.T) {
	_, err := LoadConfig(filepath.Join(t.TempDir(), "does-not-exist.yaml"))
	if err == nil {
		t.Fatal("expected an error for a missing config file")
	}
	if !strings.Contains(err.Error(), "read") {
		t.Errorf("error %q should mention reading the file", err.Error())
	}
}
