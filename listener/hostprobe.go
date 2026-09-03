package listener

import (
	"context"
	"fmt"
	"math"
	"os/exec"
	"strconv"
	"strings"
	"time"
)

// Resource names a host resource that reactive admission gates on. Each is
// checked independently: a job is admitted only when every resource keeps at
// least the reserve headroom free (#163).
type Resource string

const (
	ResourceCPU Resource = "cpu"
	ResourceMem Resource = "mem"
)

// HostResources is a single live reading of the host's free headroom per
// resource (a fraction in [0,1]; 1.0 = fully free), plus Footprint: one heavy
// job's share of the CPU (~1/nproc), the coarse global floor reactive admission
// uses to predict a burst before loadavg catches up (#163).
type HostResources struct {
	Free      map[Resource]float64
	Footprint float64
}

// CommandHostProbe is the production HostProbe: it reads raw /proc figures from
// a thin shell-out (ADR-0003 -- host inspection is bash's job) and computes the
// free-headroom fractions in Go. The command prints `key value` lines:
//
//	loadavg1 1.24
//	nproc 8
//	mem_available_kb 5928000
//	mem_total_kb 8192000
//
// From these Go derives CPU free = 1 - loadavg1/nproc (clamped to [0,1]),
// memory free = mem_available/mem_total, and Footprint = 1/nproc.
type CommandHostProbe struct {
	// Name is the probe command; there is no default (wired to host-probe.sh).
	Name string
	// Args are its arguments.
	Args []string
	// Timeout bounds the probe call; defaults to 5s.
	Timeout time.Duration
}

// Probe runs the probe command once and returns the current host headroom. It
// is called once per admission decision (unlike DeviceDetector's call-once
// sizing).
func (p CommandHostProbe) Probe(ctx context.Context) (HostResources, error) {
	timeout := p.Timeout
	if timeout <= 0 {
		timeout = 5 * time.Second
	}
	cctx, cancel := context.WithTimeout(ctx, timeout)
	defer cancel()

	out, err := exec.CommandContext(cctx, p.Name, p.Args...).Output()
	if err != nil {
		return HostResources{}, err
	}

	vals := make(map[string]float64)
	for _, line := range strings.Split(string(out), "\n") {
		if strings.TrimSpace(line) == "" {
			continue
		}
		fields := strings.Fields(line)
		if len(fields) != 2 {
			return HostResources{}, fmt.Errorf("host-probe: malformed line %q", line)
		}
		v, perr := strconv.ParseFloat(fields[1], 64)
		if perr != nil {
			return HostResources{}, fmt.Errorf("host-probe: non-numeric value for %q: %q", fields[0], fields[1])
		}
		vals[fields[0]] = v
	}

	for _, key := range []string{"loadavg1", "nproc", "mem_available_kb", "mem_total_kb"} {
		if _, ok := vals[key]; !ok {
			return HostResources{}, fmt.Errorf("host-probe: missing required key %q", key)
		}
	}
	nproc, memTotal := vals["nproc"], vals["mem_total_kb"]
	if nproc <= 0 || memTotal <= 0 {
		return HostResources{}, fmt.Errorf("host-probe: nproc (%v) and mem_total_kb (%v) must be positive", nproc, memTotal)
	}

	return HostResources{
		Free: map[Resource]float64{
			ResourceCPU: clamp01(1 - vals["loadavg1"]/nproc),
			ResourceMem: vals["mem_available_kb"] / memTotal,
		},
		Footprint: 1 / nproc,
	}, nil
}

// Binding returns the scarcest resource and its free fraction -- the constraint
// that gates admission -- for logging which resource is binding (#159 Q1a).
func (h HostResources) Binding() (Resource, float64) {
	var res Resource
	free := math.Inf(1)
	for r, f := range h.Free {
		if f < free {
			res, free = r, f
		}
	}
	return res, free
}

// admits reports whether admitting ONE more job keeps every resource at or
// above the reserve, counting the job being admitted. CPU is discounted by
// (inFlight+1)*footprint because loadavg LAGS a burst (#163): jobs that just
// started are not yet in the 1-minute average, so their load is predicted from
// the in-flight count. Memory is instantaneous (a started job shows in the very
// next MemAvailable) so it is checked raw.
func admits(h HostResources, inFlight int, reserve float64) bool {
	cpuOK := h.Free[ResourceCPU]-float64(inFlight+1)*h.Footprint >= reserve
	memOK := h.Free[ResourceMem] >= reserve
	return cpuOK && memOK
}

// admitCount returns how many ADDITIONAL jobs can be admitted now without any
// resource crossing the reserve, clamped to ceiling. It walks up from the
// current in-flight count so the coarse CPU footprint compounds per job.
func admitCount(h HostResources, inFlight int, reserve float64, ceiling int) int {
	n := 0
	for n < ceiling && admits(h, inFlight+n, reserve) {
		n++
	}
	return n
}

// clamp01 bounds x to [0,1] so a transient load spike above the core count
// cannot report negative free CPU.
func clamp01(x float64) float64 {
	switch {
	case x < 0:
		return 0
	case x > 1:
		return 1
	default:
		return x
	}
}
