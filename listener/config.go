package listener

import (
	"bytes"
	"errors"
	"fmt"
	"io"
	"os"

	"gopkg.in/yaml.v3"
)

// RunnerType is the authoritative typed shape of one runner-type config entry
// (ADR-0001 "Per-runner-type configuration"; #110). Each entry describes one
// homogeneous class of ephemeral runner and maps to exactly one GitHub scale
// set. Go is the single parser of record (ADR-0003): it reads the whole entry,
// then passes only the per-job fields a provision needs (image, devices,
// runtime, build tool) across the shell-out boundary to the
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
	// Concurrency is the worker-pool sizing for this type. Auto by default
	// (sized from host capacity, e.g. GPU count -- #113).
	Concurrency Concurrency `yaml:"concurrency"`
}

// Concurrency is a runner type's worker-pool sizing policy. The zero value is
// reactive live-admission (ADR-0005, #163): the listener admits each job
// against live per-resource headroom, keeping Reserve percent free, so the
// concurrent-runner count emerges rather than being configured. A GPU type opts
// into device-count sizing with an explicit mode: auto (#164 covers reactive
// GPU/VRAM).
type Concurrency struct {
	// Mode is "auto" (size from a detected host device count -- GPU) or empty
	// (reactive CPU/RAM live-admission, the default).
	Mode string `yaml:"mode"`
	// Reserve is the percent of each resource to keep free under reactive
	// admission. Zero means the default (defaultReservePercent); it is
	// upward-only -- an operator raises it to leave more headroom for co-tenant
	// work, and values 1..9 are rejected.
	Reserve int `yaml:"reserve"`
}

// DeviceSized reports whether this type sizes its pool from a detected device
// count (mode: auto -- GPU) rather than reactive live-admission (the default).
func (c Concurrency) DeviceSized() bool {
	return c.Mode == concurrencyAuto
}

const (
	concurrencyAuto = "auto"

	// defaultReservePercent is the per-resource headroom kept free when a
	// reactive type does not set Reserve; minReservePercent is the floor an
	// explicit Reserve may not go below (Reserve is upward-only).
	defaultReservePercent = 10
	minReservePercent     = 10
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
//
// Decoding is strict (KnownFields): an unrecognised key -- a typo'd knob like
// "reserv" for "reserve", or a field removed by a schema change -- fails the
// load naming the offending field, rather than decoding into nothing and
// leaving the real field at its zero value. Configuration never fails silently.
func LoadConfig(path string) ([]RunnerType, error) {
	raw, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("read runner-type config %s: %w", path, err)
	}
	var doc config
	dec := yaml.NewDecoder(bytes.NewReader(raw))
	dec.KnownFields(true)
	// io.EOF is an empty document, not a parse failure: leave doc zero and let
	// validate report the operator-facing "at least one runner type" error.
	if err := dec.Decode(&doc); err != nil && !errors.Is(err, io.EOF) {
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
		if err := validateBuildTool(rt.BuildTool); err != nil {
			return fmt.Errorf("%s: %w", where, err)
		}
	}
	return nil
}

// Recognised daemonless build tools (#118/#119). Empty/none means the type
// builds no images; kaniko/buildkit route build jobs to the daemonless build
// seam (lib/runner-build.sh). Anything else fails closed -- the authoritative
// parser rejects a typo rather than silently routing nowhere.
const (
	buildToolNone     = "none"
	buildToolKaniko   = "kaniko"
	buildToolBuildKit = "buildkit"
)

// validateBuildTool enforces that a type's build_tool is one the build seam can
// route to (or empty/none).
func validateBuildTool(tool string) error {
	switch tool {
	case "", buildToolNone, buildToolKaniko, buildToolBuildKit:
		return nil
	default:
		return fmt.Errorf("unknown build_tool %q (want kaniko, buildkit, or none)", tool)
	}
}

// validateConcurrency checks the per-type concurrency block: the mode must be
// recognised (empty = reactive, or "auto" = device-sized), and an explicit
// reserve must be at or above the upward-only minimum. The removed "fixed" mode
// now fails closed, so a stale config surfaces a clear migration error.
func validateConcurrency(c Concurrency) error {
	if c.Mode != "" && c.Mode != concurrencyAuto {
		return fmt.Errorf("unknown concurrency mode %q (want auto, or empty for reactive live-admission)", c.Mode)
	}
	if c.Reserve != 0 && c.Reserve < minReservePercent {
		return fmt.Errorf("concurrency reserve is upward-only, minimum %d (got %d)", minReservePercent, c.Reserve)
	}
	return nil
}
