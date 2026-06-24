package listener

import (
	"fmt"
	"os"

	"gopkg.in/yaml.v3"
)

// RunnerType is the authoritative typed shape of one runner-type config entry
// (ADR-0001 "Per-runner-type configuration"; #110). Each entry describes one
// homogeneous class of ephemeral runner and maps to exactly one GitHub scale
// set. Go is the single parser of record (ADR-0003): it reads the whole entry,
// then passes only the per-job fields a provision needs (image, devices,
// hardening profile, runtime, build tool) across the shell-out boundary to the
// bash provisioner -- bash never parses this config.
type RunnerType struct {
	// Name is the operator-facing identifier for this type, unique across the
	// config (used in logs and to disambiguate listener instances).
	Name string `yaml:"name"`
	// ScaleSet is the GitHub scale set this type binds to. Scale sets are
	// homogeneous, so the mapping is strictly one type -> one scale set (#112);
	// it must be unique across the config.
	ScaleSet string `yaml:"scale_set"`
	// Labels are the runs-on labels workflows target this type with.
	Labels []string `yaml:"labels"`
	// Image is the container image jobs of this type run in. Operators are
	// expected to pin it by digest (the schema does not enforce digest form, but
	// the GPU example and docs do).
	Image string `yaml:"image"`
	// Devices are the host device nodes passed through to the job container
	// (precise --device passthrough, no --privileged -- ADR-0001). Empty for a
	// plain CPU type.
	Devices []string `yaml:"devices"`
	// Runtime is the container runtime / hardware shim (e.g. "nvidia" for GPU,
	// or a stronger sandbox like "gvisor"/"kata" later). Empty = the engine
	// default.
	Runtime string `yaml:"runtime"`
	// BuildTool is the daemonless image builder this type offers jobs (e.g.
	// "kaniko", "buildkit"). Empty = none.
	BuildTool string `yaml:"build_tool"`
	// HardeningProfile selects the container hardening posture (e.g. "device"
	// for rootful device runners, "default"). Empty = the provisioner default.
	HardeningProfile string `yaml:"hardening_profile"`
	// Concurrency is the worker-pool sizing for this type. Auto by default
	// (sized from host capacity, e.g. GPU count -- #113).
	Concurrency Concurrency `yaml:"concurrency"`
}

// Concurrency is a runner type's worker-pool sizing policy. The zero value is
// auto (auto by default per ADR-0001): an operator opts into a fixed bound only
// by setting mode: fixed + a count.
type Concurrency struct {
	// Mode is "auto" (size from detected host capacity) or "fixed" (use Count).
	// Empty is treated as auto.
	Mode string `yaml:"mode"`
	// Count is the fixed worker-pool bound when Mode is "fixed".
	Count int `yaml:"count"`
}

// Auto reports whether this type sizes its pool from host capacity (the
// default) rather than a fixed count.
func (c Concurrency) Auto() bool {
	return c.Mode == "" || c.Mode == concurrencyAuto
}

const (
	concurrencyAuto  = "auto"
	concurrencyFixed = "fixed"
)

// config is the on-disk YAML document: a single top-level runner_types list.
type config struct {
	RunnerTypes []RunnerType `yaml:"runner_types"`
}

// LoadConfig reads, parses and validates the runner-type config at path,
// returning the typed []RunnerType or a clear non-zero error (#111). It is the
// authoritative parser (ADR-0003). It fails closed: a missing file, malformed
// YAML, or any validation failure (missing required field, empty list,
// duplicate name/scale set, bad concurrency) yields an error, never a partial
// or silently-defaulted config.
func LoadConfig(path string) ([]RunnerType, error) {
	raw, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("read runner-type config %s: %w", path, err)
	}
	var doc config
	if err := yaml.Unmarshal(raw, &doc); err != nil {
		return nil, fmt.Errorf("parse runner-type config %s: %w", path, err)
	}
	if err := validate(doc.RunnerTypes); err != nil {
		return nil, fmt.Errorf("invalid runner-type config %s: %w", path, err)
	}
	return doc.RunnerTypes, nil
}

// validate enforces the schema's required fields and value constraints across
// all entries, returning the first violation found.
func validate(types []RunnerType) error {
	if len(types) == 0 {
		return fmt.Errorf("at least one runner type is required")
	}
	seenName := make(map[string]bool, len(types))
	seenScaleSet := make(map[string]bool, len(types))
	for i, rt := range types {
		where := fmt.Sprintf("runner type #%d", i+1)
		if rt.Name != "" {
			where = fmt.Sprintf("runner type %q", rt.Name)
		}
		if rt.Name == "" {
			return fmt.Errorf("%s: name is required", where)
		}
		if rt.ScaleSet == "" {
			return fmt.Errorf("%s: scale_set is required", where)
		}
		if len(rt.Labels) == 0 {
			return fmt.Errorf("%s: at least one label is required", where)
		}
		if rt.Image == "" {
			return fmt.Errorf("%s: image is required", where)
		}
		if seenName[rt.Name] {
			return fmt.Errorf("duplicate runner type name %q", rt.Name)
		}
		seenName[rt.Name] = true
		if seenScaleSet[rt.ScaleSet] {
			return fmt.Errorf("%s: scale set %q is already bound to another runner type (one type -> one scale set)", where, rt.ScaleSet)
		}
		seenScaleSet[rt.ScaleSet] = true
		if err := validateConcurrency(rt.Concurrency); err != nil {
			return fmt.Errorf("%s: %w", where, err)
		}
	}
	return nil
}

// validateConcurrency checks the per-type concurrency block: the mode must be
// recognised, and a fixed mode needs a positive count.
func validateConcurrency(c Concurrency) error {
	switch c.Mode {
	case "", concurrencyAuto:
		return nil
	case concurrencyFixed:
		if c.Count <= 0 {
			return fmt.Errorf("concurrency mode fixed requires a positive count")
		}
		return nil
	default:
		return fmt.Errorf("unknown concurrency mode %q (want auto or fixed)", c.Mode)
	}
}
