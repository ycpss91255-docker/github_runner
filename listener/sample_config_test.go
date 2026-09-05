package listener

import (
	"path/filepath"
	"strings"
	"testing"
)

// sampleConfigPath is the shipped example runner-type config (#110), kept under
// testdata so it is reachable inside the Go-module test sandbox. It is a
// byte-identical copy of deploy/runner-types.sample.yaml (the operator-facing
// example); a bats drift guard (test/bats/integration/runner_types_config.bats) keeps the
// two in sync. Loading it through the real loader keeps the documented example
// honest -- a schema change that broke the sample would fail here.
func sampleConfigPath(t *testing.T) string {
	t.Helper()
	return filepath.Join("testdata", "runner-types.sample.yaml")
}

// The shipped sample config loads cleanly and contains the concrete GPU type
// (#113) plus a second type (#112), proving the example is valid against the
// authoritative parser.
func TestSampleConfigLoads(t *testing.T) {
	types, err := LoadConfig(sampleConfigPath(t))
	if err != nil {
		t.Fatalf("shipped sample runner-types config failed to load: %v", err)
	}
	if len(types) < 2 {
		t.Fatalf("sample should define at least two runner types, got %d", len(types))
	}
	byName := map[string]RunnerType{}
	for _, rt := range types {
		byName[rt.Name] = rt
	}
	gpu, ok := byName["gpu"]
	if !ok {
		t.Fatal("sample config is missing the concrete gpu runner type (#113)")
	}
	if gpu.ScaleSet == "" || len(gpu.Devices) == 0 || gpu.Image == "" {
		t.Errorf("gpu type under-specified: %+v", gpu)
	}
	if !gpu.Concurrency.DeviceSized() {
		t.Error("gpu type should use device-sized concurrency (= GPU count, #113)")
	}
}

// The plain CPU type references the upstream actions-runner image pinned by a
// sha256 DIGEST, never a floating :latest tag (#122). This is the AFK proof
// that the digest-pin wiring is what the authoritative parser actually loads
// from the shipped sample -- so the documented "no :latest" guarantee can't
// silently regress.
func TestCPUTypeImageIsDigestPinned(t *testing.T) {
	types, err := LoadConfig(sampleConfigPath(t))
	if err != nil {
		t.Fatalf("load sample: %v", err)
	}
	var cpu RunnerType
	for _, rt := range types {
		if rt.Name == "cpu" {
			cpu = rt
		}
	}
	if cpu.Name == "" {
		t.Fatal("sample config is missing the plain CPU runner type (#122)")
	}
	if !strings.Contains(cpu.Image, "@sha256:") {
		t.Errorf("cpu image must be pinned by sha256 digest, got %q", cpu.Image)
	}
	if strings.HasSuffix(cpu.Image, ":latest") || strings.Contains(cpu.Image, ":latest@") {
		t.Errorf("cpu image must not use a floating :latest tag, got %q", cpu.Image)
	}
}

// The GPU type's auto concurrency derives the worker-pool bound from the GPU
// count (#113): with the GPU detector stubbed to report 2 GPUs, the listener
// sizes its pool to 2 -- no real hardware needed. This is the AFK proof that the
// concrete GPU config's auto-concurrency works end to end (config -> instance ->
// resolved bound); a live GPU job actually running is the operator step.
func TestGPUTypeAutoConcurrencyFromGPUCount(t *testing.T) {
	types, err := LoadConfig(sampleConfigPath(t))
	if err != nil {
		t.Fatalf("load sample: %v", err)
	}
	var gpu RunnerType
	for _, rt := range types {
		if rt.Name == "gpu" {
			gpu = rt
		}
	}
	// Stub the GPU detector at 2 GPUs.
	inst := gpu.Instance(InstanceDeps{Detector: stubDetector{count: 2}})
	l := New(nil, nil, nil, inst.Config)
	if l.bound != 2 {
		t.Errorf("GPU pool bound = %d, want 2 (one slot per detected GPU)", l.bound)
	}
}
