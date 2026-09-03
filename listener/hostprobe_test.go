package listener

import (
	"context"
	"math"
	"testing"
)

func approxEqual(a, b float64) bool { return math.Abs(a-b) < 1e-9 }

// CommandHostProbe reads raw /proc figures from a thin shell-out (key value
// lines) and computes the free-headroom fractions in Go (ADR-0003): CPU free =
// 1 - loadavg1/nproc, memory free = mem_available/mem_total, and one heavy
// job's CPU footprint = 1/nproc. Worked from independent literals: load 2.0 on
// 8 cores -> 0.75 free; 4096000/8192000 KiB -> 0.5 free; 1/8 -> 0.125.
func TestCommandHostProbeParsesProcValues(t *testing.T) {
	stub := writeExec(t, "#!/usr/bin/env bash\nprintf 'loadavg1 2.0\\nnproc 8\\nmem_available_kb 4096000\\nmem_total_kb 8192000\\n'\n")
	p := CommandHostProbe{Name: stub, Args: []string{}}
	h, err := p.Probe(context.Background())
	if err != nil {
		t.Fatalf("Probe error: %v", err)
	}
	if got := h.Free[ResourceCPU]; !approxEqual(got, 0.75) {
		t.Errorf("Free[cpu] = %v, want 0.75 (1 - 2.0/8)", got)
	}
	if got := h.Free[ResourceMem]; !approxEqual(got, 0.5) {
		t.Errorf("Free[mem] = %v, want 0.5 (4096000/8192000)", got)
	}
	if !approxEqual(h.Footprint, 0.125) {
		t.Errorf("Footprint = %v, want 0.125 (1/8)", h.Footprint)
	}
}

// A failing / absent probe command surfaces an error so the caller can fall
// back to the conservative path rather than trusting a partial reading.
func TestCommandHostProbeErrorsWhenCommandFails(t *testing.T) {
	stub := writeExec(t, "#!/usr/bin/env bash\nexit 1\n")
	p := CommandHostProbe{Name: stub}
	if _, err := p.Probe(context.Background()); err == nil {
		t.Fatal("expected an error when the probe command exits non-zero")
	}
}

// A reading that is missing a required key, carries a non-numeric value, or
// reports a zero divisor must error rather than silently computing headroom
// from a defaulted zero (which would misjudge admission).
func TestCommandHostProbeErrorsOnMissingOrMalformed(t *testing.T) {
	cases := map[string]string{
		"missing mem keys":  "#!/usr/bin/env bash\nprintf 'loadavg1 1.0\\nnproc 8\\n'\n",
		"non-numeric value": "#!/usr/bin/env bash\nprintf 'loadavg1 x\\nnproc 8\\nmem_available_kb 1\\nmem_total_kb 2\\n'\n",
		"zero nproc":        "#!/usr/bin/env bash\nprintf 'loadavg1 1.0\\nnproc 0\\nmem_available_kb 1\\nmem_total_kb 2\\n'\n",
	}
	for name, body := range cases {
		t.Run(name, func(t *testing.T) {
			stub := writeExec(t, body)
			p := CommandHostProbe{Name: stub}
			if _, err := p.Probe(context.Background()); err == nil {
				t.Errorf("expected an error for %s", name)
			}
		})
	}
}
