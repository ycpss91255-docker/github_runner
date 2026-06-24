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

// Instance maps this runner type to its scale-set listener inputs. Concurrency
// is resolved here: a fixed mode pins Config.MaxRunners to the count (an
// operator override that always wins); auto mode leaves MaxRunners 0 and
// attaches det so the listener sizes the pool from detected host capacity
// (#113: GPU count). det may be nil for an auto type, in which case the
// listener falls back to its conservative default bound.
func (rt RunnerType) Instance(det DeviceDetector) Instance {
	cfg := Config{
		Image:            rt.Image,
		Devices:          rt.Devices,
		HardeningProfile: rt.HardeningProfile,
		BuildTool:        rt.BuildTool,
	}
	if rt.Concurrency.Auto() {
		cfg.DeviceDetector = det
	} else {
		cfg.MaxRunners = rt.Concurrency.Count
	}
	return Instance{
		Name:     rt.Name,
		ScaleSet: rt.ScaleSet,
		Labels:   rt.Labels,
		Config:   cfg,
	}
}

// Instances maps every loaded runner type to its scale-set listener inputs,
// sharing one device detector across the auto-sized types. The result is one
// Instance per type, each independently bound to its own scale set, image and
// concurrency -- the basis for running multiple types side by side from a
// single config file.
func Instances(types []RunnerType, det DeviceDetector) []Instance {
	insts := make([]Instance, 0, len(types))
	for _, rt := range types {
		insts = append(insts, rt.Instance(det))
	}
	return insts
}
