package listener

import (
	"context"
	"errors"
	"sync"
	"testing"
	"time"

	"github.com/actions/scaleset"
)

// countingProbe returns an over-the-line reading for its first overUntil calls,
// then a healthy one, so a test can prove admission re-probes after settling.
type countingProbe struct {
	mu        sync.Mutex
	calls     int
	overUntil int
	over      HostResources
	ok        HostResources
	err       error
}

func (p *countingProbe) Probe(context.Context) (HostResources, error) {
	p.mu.Lock()
	defer p.mu.Unlock()
	p.calls++
	if p.err != nil {
		return HostResources{}, p.err
	}
	if p.calls <= p.overUntil {
		return p.over, nil
	}
	return p.ok, nil
}

func (p *countingProbe) callCount() int {
	p.mu.Lock()
	defer p.mu.Unlock()
	return p.calls
}

// Capacity reported to GitHub is derived from live headroom (no fixed bound, no
// per-workload cost table): a batch far from the line, exactly 1 near the line
// (source-level serialization), and a conservative 1 when the probe fails
// (never 0, which would starve). MaxRunners is set high so the safety ceiling
// never binds -- the reactive math is what is under test.
func TestReactiveCapacityFromHeadroom(t *testing.T) {
	newL := func(p HostProbe) *Listener {
		return New(&fakeSession{}, &recordingMinter{}, &recordingProvisioner{},
			Config{HostProbe: p, Reserve: 10, MaxRunners: 100})
	}
	// Abundant: cpu free 1.0, footprint 0.125, reserve 0.10 -> 7 fit.
	abundant := newL(stubProbe{res: HostResources{Free: map[Resource]float64{ResourceCPU: 1.0, ResourceMem: 1.0}, Footprint: 0.125}})
	if got := abundant.capacityFor(0); got != 7 {
		t.Errorf("abundant capacity = %d, want 7", got)
	}
	// Near the line: cpu free 0.30 -> admits(0)=0.175>=.10 but admits(1)=0.05<.10 -> exactly 1.
	nearLine := newL(stubProbe{res: HostResources{Free: map[Resource]float64{ResourceCPU: 0.30, ResourceMem: 1.0}, Footprint: 0.125}})
	if got := nearLine.capacityFor(0); got != 1 {
		t.Errorf("near-line capacity = %d, want 1", got)
	}
	// Probe failure: conservative 1, never 0.
	failing := newL(stubProbe{err: errors.New("probe boom")})
	if got := failing.capacityFor(0); got != 1 {
		t.Errorf("probe-failure capacity = %d, want 1 (conservative)", got)
	}
}

// The #163 success criterion: a burst of 8 CPU-heavy shards arriving in one
// message must never breach the 10% line. On an 8-core-equivalent host
// (footprint 0.125, cpu free 1.0), reactive admission lets 7 run (12.5% free)
// and parks the 8th until a slot frees, self-healing when a job finishes. The
// safety ceiling (MaxRunners) is set high so only the reactive gate binds.
func TestReactiveBurstNeverBreachesReserve(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	jobs := make([]*scaleset.JobAssigned, 8)
	for i := range jobs {
		jobs[i] = assigned(int64(i+1), string(rune('a'+i)))
	}
	sess := &fakeSession{
		messages: []*scaleset.RunnerScaleSetMessage{msgWithAssigned(1, 8, jobs...)},
		cancel:   cancel,
	}
	probe := &concurrencyProbe{
		started: make(chan struct{}, 8),
		release: make(chan struct{}),
	}
	l := New(sess, &recordingMinter{config: "jit"}, probe, Config{
		Image:        "img",
		HostProbe:    stubProbe{res: HostResources{Free: map[Resource]float64{ResourceCPU: 1.0, ResourceMem: 1.0}, Footprint: 0.125}},
		Reserve:      10,
		SettleWindow: time.Millisecond,
		MaxRunners:   100,
	})

	done := make(chan struct{})
	go func() { _ = l.Listen(ctx); close(done) }()

	// Exactly 7 may start; the 8th must park (reactive gate, not the semaphore).
	for i := 0; i < 7; i++ {
		select {
		case <-probe.started:
		case <-time.After(2 * time.Second):
			t.Fatalf("only %d of 7 shards started before the reserve line", i)
		}
	}
	select {
	case <-probe.started:
		t.Fatal("an 8th shard started -- the burst breached the 10% reserve line")
	case <-time.After(150 * time.Millisecond):
		// good: the 8th is parked, waiting for headroom.
	}
	if got := probe.peakLive(); got > 7 {
		t.Fatalf("peak concurrency %d breached the reserve line (want <= 7)", got)
	}

	// Self-heal: releasing the running shards frees headroom, so the 8th admits.
	close(probe.release)
	select {
	case <-probe.started:
	case <-time.After(2 * time.Second):
		t.Fatal("the parked 8th shard never admitted after a slot freed")
	}
	cancel()
	<-done
	if got := probe.peakLive(); got > 7 {
		t.Fatalf("peak concurrency %d breached the reserve line over the whole run", got)
	}
}

// Near/over the line, admission settles and re-probes rather than admitting or
// giving up: once headroom returns, the parked job admits.
func TestAdmitOneSettlesThenAdmits(t *testing.T) {
	p := &countingProbe{
		overUntil: 2,
		over:      HostResources{Free: map[Resource]float64{ResourceCPU: 0.0, ResourceMem: 1.0}, Footprint: 0.125},
		ok:        HostResources{Free: map[Resource]float64{ResourceCPU: 1.0, ResourceMem: 1.0}, Footprint: 0.125},
	}
	l := New(&fakeSession{}, &recordingMinter{}, &recordingProvisioner{},
		Config{HostProbe: p, Reserve: 10, SettleWindow: time.Millisecond, MaxRunners: 100})
	if !l.admitOne(context.Background()) {
		t.Fatal("admitOne should admit once headroom returns")
	}
	if p.callCount() < 3 {
		t.Errorf("expected re-probing after settle, calls = %d, want >= 3", p.callCount())
	}
}

// A context cancelled while admission is parked over the line unblocks cleanly
// (returns false) rather than settling forever.
func TestAdmitOneCtxCancelUnblocks(t *testing.T) {
	p := &countingProbe{
		overUntil: 1 << 30, // always over the line
		over:      HostResources{Free: map[Resource]float64{ResourceCPU: 0.0, ResourceMem: 1.0}, Footprint: 0.125},
	}
	l := New(&fakeSession{}, &recordingMinter{}, &recordingProvisioner{},
		Config{HostProbe: p, Reserve: 10, SettleWindow: time.Hour, MaxRunners: 100})
	ctx, cancel := context.WithCancel(context.Background())
	go func() {
		time.Sleep(10 * time.Millisecond)
		cancel()
	}()
	if l.admitOne(ctx) {
		t.Fatal("admitOne must return false when the context is cancelled while over the line")
	}
}
