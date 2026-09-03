package listener

// Instance is one runner type mapped to the inputs for a single scale-set
// listener (#112): the scale set it binds to, plus the listener Config that
// carries the type's image and concurrency policy. One runner type -> one
// homogeneous scale set -> one listener instance (ADR-0001). Producing an
// Instance from a RunnerType is pure data wiring, so adding a second type is a
// config entry, not a code change.
//
// ScaleSet and Labels are surfaced alongside Config because the production
// entrypoint resolves the scale set by name and opens its session before
// building the Listener; Config holds the per-job knobs the listener already
// understands (Image, MaxRunners, DeviceDetector).
type Instance struct {
	// Name is the runner type's identifier (for logs / which session is which).
	Name string
	// ScaleSet is the GitHub scale set this listener binds to.
	ScaleSet string
	// Labels are the type's runs-on labels (informational; the scale set pins
	// labels for its runners).
	Labels []string
	// Config is the listener configuration derived from the type: image, the
	// resolved concurrency policy (fixed MaxRunners, or an attached detector for
	// auto), and so on.
	Config Config
}

// InstanceDeps are the shared host-inspection seams wired into every instance:
// the GPU device detector for mode: auto types, and the reactive host probe for
// the default (reactive live-admission) types. Either may be nil, in which case
// the listener falls back to its conservative default bound.
type InstanceDeps struct {
	Detector  DeviceDetector
	HostProbe HostProbe
}

// Instance maps this runner type to its scale-set listener inputs. Concurrency
// is resolved here: mode: auto attaches the device detector so the listener
// sizes the pool from detected host capacity (#113: GPU count); the default
// (reactive) attaches the host probe and carries the reserve so the listener
// admits each job against live headroom (ADR-0005, #163). There is no fixed
// operator count -- the concurrent-runner number is derived, not configured.
func (rt RunnerType) Instance(deps InstanceDeps) Instance {
	cfg := Config{
		Image:            rt.Image,
		Devices:          rt.Devices,
		HardeningProfile: rt.HardeningProfile,
		BuildTool:        rt.BuildTool,
	}
	if rt.Concurrency.DeviceSized() {
		cfg.DeviceDetector = deps.Detector
	} else {
		cfg.HostProbe = deps.HostProbe
		cfg.Reserve = rt.Concurrency.Reserve
	}
	return Instance{
		Name:     rt.Name,
		ScaleSet: rt.ScaleSet,
		Labels:   rt.Labels,
		Config:   cfg,
	}
}

// Instances maps every loaded runner type to its scale-set listener inputs,
// sharing one set of host-inspection deps across all types. The result is one
// Instance per type, each independently bound to its own scale set, image and
// concurrency -- the basis for running multiple types side by side from a
// single config file.
func Instances(types []RunnerType, deps InstanceDeps) []Instance {
	insts := make([]Instance, 0, len(types))
	for _, rt := range types {
		insts = append(insts, rt.Instance(deps))
	}
	return insts
}
