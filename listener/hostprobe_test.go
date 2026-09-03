package listener

import (
	"context"
	"math"
	"testing"
)

func approxEqual(a, b float64) bool { return math.Abs(a-b) < 1e-9 }

// stubProbe injects a fixed host reading (or error) so admission behaviour can
// be exercised without a real host, the HostProbe analog of stubDetector.
type stubProbe struct {
	res HostResources
	err error
}

func (s stubProbe) Probe(context.Context) (HostResources, error) { return s.res, s.err }

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

// admits gates each resource independently against the reserve. CPU is
// discounted by (inFlight+1)*footprint because loadavg lags a burst; memory is
// checked raw. On an 8-core host (footprint 0.125) at reserve 0.10, admitting
// the k-th extra job keeps CPU free = 1 - (k+1)*0.125, so it holds through
// inFlight 6 (0.125 free) and refuses at 7 (0.0 free).
func TestAdmitsGatesEachResource(t *testing.T) {
	full := HostResources{Free: map[Resource]float64{ResourceCPU: 1.0, ResourceMem: 1.0}, Footprint: 0.125}
	memTight := HostResources{Free: map[Resource]float64{ResourceCPU: 1.0, ResourceMem: 0.05}, Footprint: 0.125}
	cases := []struct {
		name     string
		h        HostResources
		inFlight int
		reserve  float64
		want     bool
	}{
		{"abundant admits", full, 0, 0.10, true},
		{"cpu just under the line admits", full, 6, 0.10, true},
		{"cpu at the line refuses", full, 7, 0.10, false},
		{"memory binding refuses despite free cpu", memTight, 0, 0.10, false},
	}
	for _, c := range cases {
		if got := admits(c.h, c.inFlight, c.reserve); got != c.want {
			t.Errorf("%s: admits(inFlight=%d) = %v, want %v", c.name, c.inFlight, got, c.want)
		}
	}
}

// admitCount reports how many MORE jobs fit: it walks up from the current
// in-flight count until the next job would cross the reserve, clamped to the
// ceiling.
func TestAdmitCountStopsAtReserveAndCeiling(t *testing.T) {
	full := HostResources{Free: map[Resource]float64{ResourceCPU: 1.0, ResourceMem: 1.0}, Footprint: 0.125}
	if got := admitCount(full, 0, 0.10, 100); got != 7 {
		t.Errorf("admitCount abundant = %d, want 7", got)
	}
	if got := admitCount(full, 0, 0.10, 3); got != 3 {
		t.Errorf("admitCount clamped to ceiling = %d, want 3", got)
	}
	if got := admitCount(full, 7, 0.10, 100); got != 0 {
		t.Errorf("admitCount already at the line = %d, want 0", got)
	}
}

// Binding names the scarcest resource and its free fraction, for logging which
// resource is the constraint (#159 Q1a).
func TestBindingNamesScarcestResource(t *testing.T) {
	h := HostResources{Free: map[Resource]float64{ResourceCPU: 0.8, ResourceMem: 0.2}}
	r, free := h.Binding()
	if r != ResourceMem || !approxEqual(free, 0.2) {
		t.Errorf("Binding = (%v, %v), want (mem, 0.2)", r, free)
	}
}
