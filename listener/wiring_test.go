package listener

import (
	"testing"
)

// A runner type maps to a listener Config bound to its scale set, image and
// hardening/runtime/device settings, so the type alone drives a listener
// instance (#112). Auto concurrency leaves MaxRunners 0 (the device detector
// sizes the bound) and attaches the detector.
func TestRunnerTypeToConfigAuto(t *testing.T) {
	det := stubDetector{count: 3}
	rt := RunnerType{
		Name:             "gpu",
		ScaleSet:         "gpu-runners",
		Labels:           []string{"self-hosted", "gpu"},
		Image:            "img-gpu@sha256:1",
		Devices:          []string{"/dev/nvidia0"},
		Runtime:          "nvidia",
		HardeningProfile: "device",
		Concurrency:      Concurrency{Mode: "auto"},
	}
	inst := rt.Instance(det)

	if inst.ScaleSet != "gpu-runners" {
		t.Errorf("ScaleSet = %q, want gpu-runners", inst.ScaleSet)
	}
	if inst.Config.Image != "img-gpu@sha256:1" {
		t.Errorf("Image = %q", inst.Config.Image)
	}
	if inst.Config.MaxRunners != 0 {
		t.Errorf("auto concurrency should leave MaxRunners 0, got %d", inst.Config.MaxRunners)
	}
	if inst.Config.DeviceDetector == nil {
		t.Error("auto concurrency should attach the device detector")
	}
	// The resolved bound should come from the detector (GPU count -> 3).
	l := New(nil, nil, nil, inst.Config)
	if l.bound != 3 {
		t.Errorf("resolved bound = %d, want 3 (GPU count)", l.bound)
	}
}

// Fixed concurrency sets MaxRunners to the count and does NOT attach a detector,
// so an operator-pinned bound wins regardless of hardware.
func TestRunnerTypeToConfigFixed(t *testing.T) {
	rt := RunnerType{
		Name:        "cpu",
		ScaleSet:    "cpu-runners",
		Labels:      []string{"self-hosted", "cpu"},
		Image:       "img-cpu@sha256:2",
		Concurrency: Concurrency{Mode: "fixed", Count: 4},
	}
	inst := rt.Instance(stubDetector{count: 99})

	if inst.Config.MaxRunners != 4 {
		t.Errorf("MaxRunners = %d, want 4", inst.Config.MaxRunners)
	}
	if inst.Config.DeviceDetector != nil {
		t.Error("fixed concurrency should not attach a device detector")
	}
	l := New(nil, nil, nil, inst.Config)
	if l.bound != 4 {
		t.Errorf("resolved bound = %d, want 4 (fixed, ignores 99 devices)", l.bound)
	}
}

// Two distinct types yield two independent instances bound to their own scale
// sets and images -- multiple types run side by side with no code change (#112).
func TestInstancesFromTypes(t *testing.T) {
	types := []RunnerType{
		{Name: "gpu", ScaleSet: "gpu-runners", Labels: []string{"gpu"}, Image: "g@sha256:1", Concurrency: Concurrency{Mode: "auto"}},
		{Name: "cpu", ScaleSet: "cpu-runners", Labels: []string{"cpu"}, Image: "c@sha256:2", Concurrency: Concurrency{Mode: "fixed", Count: 2}},
	}
	insts := Instances(types, stubDetector{count: 1})
	if len(insts) != 2 {
		t.Fatalf("got %d instances, want 2", len(insts))
	}
	if insts[0].ScaleSet != "gpu-runners" || insts[0].Config.Image != "g@sha256:1" {
		t.Errorf("instance 0 = %+v", insts[0])
	}
	if insts[1].ScaleSet != "cpu-runners" || insts[1].Config.MaxRunners != 2 {
		t.Errorf("instance 1 = %+v", insts[1])
	}
}
