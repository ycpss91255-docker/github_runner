package listener

import (
	"context"
	"errors"
	"sync"
	"testing"
	"time"

	"github.com/actions/scaleset"
)

// fakeSession is an in-memory stand-in for the official scale-set session
// (*scaleset.MessageSessionClient). It feeds a scripted sequence of messages
// to the listener's long-poll loop and records the demand (maxCapacity) the
// listener reports back, plus the messages it acked and whether it was closed
// -- so the tests can assert the loop without any GitHub round-trip. The real
// client satisfies the same Session interface (proven by the compile-time
// assertion in listener.go), so the listener cannot tell them apart.
type fakeSession struct {
	mu             sync.Mutex
	messages       []*scaleset.RunnerScaleSetMessage // scripted, drained front-to-back
	getErr         error                             // returned once messages are drained (a real transport error)
	cancel         context.CancelFunc                // if set, called when messages drain to end the loop via ctx
	reportedCap    []int                             // maxCapacity passed to each GetMessage
	deletedIDs     []int                             // messageIDs acked via DeleteMessage
	acquiredReqIDs [][]int64                         // requestIDs passed to each AcquireJobs
	closed         bool                              // Close was called (teardown)
}

func (f *fakeSession) GetMessage(ctx context.Context, _ int, maxCapacity int) (*scaleset.RunnerScaleSetMessage, error) {
	f.mu.Lock()
	f.reportedCap = append(f.reportedCap, maxCapacity)
	f.mu.Unlock()
	if len(f.messages) == 0 {
		// A genuine transport error ends the loop with that error.
		if f.getErr != nil {
			return nil, f.getErr
		}
		// Otherwise the scripted run is done: cancel the context (as a real
		// shutdown/SIGTERM would) so the loop terminates the only sanctioned
		// way -- via ctx -- and surface the resulting context error.
		if f.cancel != nil {
			f.cancel()
		}
		return nil, ctx.Err()
	}
	msg := f.messages[0]
	f.messages = f.messages[1:]
	return msg, nil
}

func (f *fakeSession) AcquireJobs(_ context.Context, requestIDs []int64) ([]int64, error) {
	f.acquiredReqIDs = append(f.acquiredReqIDs, requestIDs)
	return requestIDs, nil
}

func (f *fakeSession) DeleteMessage(_ context.Context, messageID int) error {
	f.mu.Lock()
	f.deletedIDs = append(f.deletedIDs, messageID)
	f.mu.Unlock()
	return nil
}

// ackedIDs returns the messageIDs acked so far, race-free.
func (f *fakeSession) ackedIDs() []int {
	f.mu.Lock()
	defer f.mu.Unlock()
	return append([]int(nil), f.deletedIDs...)
}

func (f *fakeSession) Session() scaleset.RunnerScaleSetSession {
	return scaleset.RunnerScaleSetSession{}
}

func (f *fakeSession) Close(_ context.Context) error {
	f.closed = true
	return nil
}

// recordingMinter is a mock of the JIT minter seam (the production
// implementation calls the scale-set client's GenerateJitRunnerConfig). It
// returns a scripted encoded config per job name and records every mint call so
// a test can assert the assigned job was minted with the expected name.
type recordingMinter struct {
	config   string   // encoded JIT config to return
	mintErr  error    // returned instead, if set
	gotNames []string // job names passed to Mint
}

func (m *recordingMinter) Mint(_ context.Context, name string, _ []string) (string, error) {
	m.gotNames = append(m.gotNames, name)
	if m.mintErr != nil {
		return "", m.mintErr
	}
	return m.config, nil
}

// recordingProvisioner is a mock of the per-job container provisioner glue.
// It records every job it was asked to provision (so a test can assert an
// ASSIGNED job triggered the shell-out, and with which JIT config), and can be
// told to fail to exercise the error path.
type recordingProvisioner struct {
	mu      sync.Mutex
	jobs    []ProvisionRequest
	failOn  string        // RequestID-bearing JobID to fail; "" never fails
	failErr error         // returned by every Provision when set
	started chan struct{} // if set, closed/signalled when Provision begins
	block   chan struct{} // if set, Provision blocks until this is closed
}

func (r *recordingProvisioner) Provision(_ context.Context, req ProvisionRequest) error {
	r.mu.Lock()
	r.jobs = append(r.jobs, req)
	r.mu.Unlock()
	if r.started != nil {
		r.started <- struct{}{}
	}
	if r.block != nil {
		<-r.block
	}
	// failOn scopes the failure to a single JobID; empty failOn means every
	// job fails when failErr is set.
	if r.failErr != nil && (r.failOn == "" || r.failOn == req.JobID) {
		return r.failErr
	}
	return nil
}

// jobCount returns how many jobs have been provisioned so far, race-free.
func (r *recordingProvisioner) jobCount() int {
	r.mu.Lock()
	defer r.mu.Unlock()
	return len(r.jobs)
}

func assigned(requestID int64, jobID string, labels ...string) *scaleset.JobAssigned {
	ja := &scaleset.JobAssigned{}
	ja.RunnerRequestID = requestID
	ja.JobID = jobID
	ja.RequestLabels = labels
	return ja
}

func msgWithAssigned(id int, totalAssigned int, jobs ...*scaleset.JobAssigned) *scaleset.RunnerScaleSetMessage {
	return &scaleset.RunnerScaleSetMessage{
		MessageID:           id,
		Statistics:          &scaleset.RunnerScaleSetStatistic{TotalAssignedJobs: totalAssigned},
		JobAssignedMessages: jobs,
	}
}

// An ASSIGNED job must shell out to the per-job container provisioner, and the
// JIT config that the listener minted for that job must be handed through.
func TestAssignedJobTriggersProvisioner(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	sess := &fakeSession{
		messages: []*scaleset.RunnerScaleSetMessage{
			msgWithAssigned(1, 1, assigned(42, "job-abc", "gpu")),
		},
		cancel: cancel,
	}
	prov := &recordingProvisioner{}
	minter := &recordingMinter{config: "ENCODED-JIT-job-abc"}
	l := New(sess, minter, prov, Config{
		Image:            "ghcr.io/acme/runner:latest",
		Devices:          []string{"/dev/nvidia0", "/dev/nvidiactl"},
		HardeningProfile: "device",
	})

	if err := l.Listen(ctx); err != nil && !errors.Is(err, context.Canceled) {
		t.Fatalf("Listen returned unexpected error: %v", err)
	}
	if len(prov.jobs) != 1 {
		t.Fatalf("expected exactly 1 provisioned job, got %d", len(prov.jobs))
	}
	got := prov.jobs[0]
	if got.JobID != "job-abc" {
		t.Errorf("provisioned wrong job: got %q want %q", got.JobID, "job-abc")
	}
	// The config handed to the provisioner must be the one the minter produced
	// for this job -- proving the Go-client JIT mint is wired through, not a
	// placeholder.
	if got.EncodedJITConfig != "ENCODED-JIT-job-abc" {
		t.Errorf("provisioner got wrong JIT config: got %q want the minted %q", got.EncodedJITConfig, "ENCODED-JIT-job-abc")
	}
	if len(minter.gotNames) != 1 {
		t.Errorf("expected exactly 1 mint call, got %d", len(minter.gotNames))
	}
	if got.Image != "ghcr.io/acme/runner:latest" {
		t.Errorf("provisioner got wrong image: %q", got.Image)
	}
	// The widened shell-out contract (#117): the type's precise device list and
	// hardening profile flow from Config into every ProvisionRequest, so the
	// bash provisioner can pass exactly these as --device under the right posture.
	if len(got.Devices) != 2 || got.Devices[0] != "/dev/nvidia0" || got.Devices[1] != "/dev/nvidiactl" {
		t.Errorf("provisioner got wrong devices: %v", got.Devices)
	}
	if got.HardeningProfile != "device" {
		t.Errorf("provisioner got wrong hardening profile: %q", got.HardeningProfile)
	}
}

// Reported capacity is LOCALLY derived (#102): the first poll, with nothing
// in-flight, offers the full pool bound -- and crucially it does NOT track the
// server's TotalAssignedJobs (a large statistic must not shrink the offer when
// nothing is actually running locally).
func TestInitialCapacityIsFullPoolBound(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	sess := &fakeSession{
		messages: []*scaleset.RunnerScaleSetMessage{
			// TotalAssignedJobs=3 is deliberately non-zero: under the old
			// server-derived capacity this poll would have dropped to 5-3=2.
			msgWithAssigned(1, 3, assigned(1, "j1")),
		},
		cancel: cancel,
	}
	prov := &recordingProvisioner{}
	l := New(sess, &recordingMinter{config: "jit"}, prov, Config{Image: "img", MaxRunners: 5})

	_ = l.Listen(ctx)

	if len(sess.reportedCap) < 1 {
		t.Fatalf("expected at least 1 GetMessage call, got %d", len(sess.reportedCap))
	}
	// First poll: nothing in-flight, capacity is the full pool bound.
	if sess.reportedCap[0] != 5 {
		t.Errorf("initial capacity: got %d want 5 (pool bound)", sess.reportedCap[0])
	}
	// Every reported capacity must stay within [0, bound] and never be derived
	// from the server's TotalAssignedJobs (the j1 job finishes promptly via the
	// non-blocking recordingProvisioner, so headroom returns to the full bound).
	for i, c := range sess.reportedCap {
		if c < 0 || c > 5 {
			t.Errorf("reportedCap[%d]=%d outside [0,5]", i, c)
		}
	}
}

// Each processed message must be acked (DeleteMessage) so the long-poll does
// not redeliver it -- the at-least-once message protocol the client expects.
func TestProcessedMessageIsAcked(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	sess := &fakeSession{
		messages: []*scaleset.RunnerScaleSetMessage{
			msgWithAssigned(7, 1, assigned(1, "j1")),
		},
		cancel: cancel,
	}
	prov := &recordingProvisioner{}
	l := New(sess, &recordingMinter{config: "jit"}, prov, Config{Image: "img"})

	_ = l.Listen(ctx)

	if len(sess.deletedIDs) != 1 || sess.deletedIDs[0] != 7 {
		t.Errorf("expected message 7 to be acked, got %v", sess.deletedIDs)
	}
}

// The message must be acked (DeleteMessage) once its jobs are acquired/
// dispatched, NOT after the container exits -- otherwise a long-running job
// would leave the message unacked for its whole duration. With a provisioner
// that blocks (a slow job), the ack must still land.
func TestMessageAckedOnAcquireNotAfterJobFinishes(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	sess := &fakeSession{
		messages: []*scaleset.RunnerScaleSetMessage{
			msgWithAssigned(9, 1, assigned(1, "slow-job")),
		},
		cancel: cancel,
	}
	prov := &recordingProvisioner{
		started: make(chan struct{}, 1),
		block:   make(chan struct{}),
	}
	l := New(sess, &recordingMinter{config: "jit"}, prov, Config{Image: "img"})

	done := make(chan struct{})
	go func() { _ = l.Listen(ctx); close(done) }()

	// Wait until the (blocking) provisioner has begun the long job.
	select {
	case <-prov.started:
	case <-time.After(2 * time.Second):
		t.Fatal("provisioner never started")
	}

	// While the job is STILL blocked, the message must already be acked.
	acked := false
	for i := 0; i < 100; i++ {
		if len(sess.ackedIDs()) == 1 {
			acked = true
			break
		}
		time.Sleep(5 * time.Millisecond)
	}
	if !acked {
		t.Fatal("message was not acked while the job was still running (ack waits for job to finish)")
	}
	if got := sess.ackedIDs(); got[0] != 9 {
		t.Errorf("acked wrong message: got %v want [9]", got)
	}

	// Let the slow job finish and the loop wind down.
	close(prov.block)
	cancel()
	<-done
}

// A failing provisioner (a job's container exits non-zero) is a PER-JOB
// outcome: it must be logged and the loop must continue, NOT returned and NOT
// close the session. A later message must still be processed -- proving the
// failure did not tear the session down.
func TestProvisionerErrorIsIsolatedLoopContinues(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	sess := &fakeSession{
		messages: []*scaleset.RunnerScaleSetMessage{
			msgWithAssigned(1, 1, assigned(1, "boom")),  // this job fails
			msgWithAssigned(2, 1, assigned(2, "after")), // must still be processed
		},
		cancel: cancel,
	}
	wantErr := errors.New("container exited 1")
	prov := &recordingProvisioner{failErr: wantErr, failOn: "boom"}
	var loggedJobErrs []error
	l := New(sess, &recordingMinter{config: "jit"}, prov, Config{
		Image:    "img",
		OnJobErr: func(_ ProvisionRequest, err error) { loggedJobErrs = append(loggedJobErrs, err) },
	})

	err := l.Listen(ctx)

	// The loop ends ONLY via ctx cancellation -- the per-job failure must not
	// have been returned.
	if !errors.Is(err, context.Canceled) {
		t.Errorf("per-job failure must not end the loop; got %v want context.Canceled", err)
	}
	// Both messages were processed -- the loop continued past the failed job.
	if prov.jobCount() != 2 {
		t.Errorf("expected the loop to continue and provision the 2nd job, got %d provisions", prov.jobCount())
	}
	// The failure was logged as a per-job outcome.
	if len(loggedJobErrs) != 1 || !errors.Is(loggedJobErrs[0], wantErr) {
		t.Errorf("expected the per-job failure to be logged once, got %v", loggedJobErrs)
	}
	// Both messages acked despite the failure (ack-on-acquire, #99).
	if got := sess.ackedIDs(); len(got) != 2 {
		t.Errorf("expected both messages acked, got %v", got)
	}
}

// The loop terminates ONLY via context cancellation (no string sentinel), and
// that teardown path must still close the session.
func TestContextCancellationEndsLoopAndTearsDownSession(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	sess := &fakeSession{messages: nil, cancel: cancel}
	prov := &recordingProvisioner{}
	l := New(sess, &recordingMinter{config: "jit"}, prov, Config{Image: "img"})

	err := l.Listen(ctx)
	if !errors.Is(err, context.Canceled) {
		t.Errorf("expected ctx cancellation to surface as context.Canceled, got %v", err)
	}
	if !sess.closed {
		t.Error("expected the session to be torn down (Close) on ctx cancellation")
	}
}

// A non-context GetMessage error (a genuine transport/session failure) is
// FATAL: it must be returned from the loop, not swallowed, and the session is
// still torn down.
func TestTransportErrorIsFatal(t *testing.T) {
	wantErr := errors.New("transport boom")
	sess := &fakeSession{messages: nil, getErr: wantErr}
	prov := &recordingProvisioner{}
	l := New(sess, &recordingMinter{config: "jit"}, prov, Config{Image: "img"})

	err := l.Listen(context.Background())
	if !errors.Is(err, wantErr) {
		t.Errorf("expected the transport error to surface, got %v", err)
	}
	if !sess.closed {
		t.Error("expected the session to be torn down (Close) on a transport error")
	}
}

// A message that carries an available-but-not-assigned job (no JobAssigned
// entries) must NOT shell out -- only ASSIGNED jobs get a container, since
// only those are ours to run. Guards against over-provisioning on availability.
func TestAvailableButUnassignedDoesNotProvision(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	sess := &fakeSession{
		messages: []*scaleset.RunnerScaleSetMessage{
			msgWithAssigned(1, 0 /* no assigned jobs */),
		},
		cancel: cancel,
	}
	prov := &recordingProvisioner{}
	l := New(sess, &recordingMinter{config: "jit"}, prov, Config{Image: "img"})

	_ = l.Listen(ctx)

	if len(prov.jobs) != 0 {
		t.Errorf("expected no provisioning for an unassigned message, got %d", len(prov.jobs))
	}
}

// The real scale-set client must satisfy the Session interface, so the
// production wiring can hand a *scaleset.MessageSessionClient straight in. A
// compile-time assertion lives in listener.go; this test documents the intent.
func TestRealClientSatisfiesSession(t *testing.T) {
	var _ Session = (*scaleset.MessageSessionClient)(nil)
}

// --- #105 reaper wiring (startup + periodic) ----------------------------------

// recordingReaper records every sweep, with the tracked job ids it was handed,
// so a test can prove the listener sweeps on startup and on its interval.
type recordingReaper struct {
	mu     sync.Mutex
	sweeps [][]string
}

func (r *recordingReaper) Reap(_ context.Context, tracked []string) error {
	r.mu.Lock()
	r.sweeps = append(r.sweeps, append([]string(nil), tracked...))
	r.mu.Unlock()
	return nil
}

func (r *recordingReaper) sweepCount() int {
	r.mu.Lock()
	defer r.mu.Unlock()
	return len(r.sweeps)
}

// The listener must sweep orphans ON STARTUP (#105): before/around the first
// poll, the reaper runs at least once so a crash's leftovers are cleared.
func TestReaperSweepsOnStartup(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	sess := &fakeSession{messages: nil, cancel: cancel}
	reaper := &recordingReaper{}
	l := New(sess, &recordingMinter{config: "jit"}, &recordingProvisioner{},
		Config{Image: "img", Reaper: reaper})

	_ = l.Listen(ctx)

	if reaper.sweepCount() < 1 {
		t.Fatalf("expected at least one startup sweep, got %d", reaper.sweepCount())
	}
}

// The listener must sweep orphans PERIODICALLY (#105): with a short interval and
// a loop kept alive by a blocking provisioner, the reaper fires more than once.
func TestReaperSweepsPeriodically(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	// A provisioner that blocks the one job keeps the loop running long enough
	// for several reaper ticks.
	probe := &concurrencyProbe{
		started: make(chan struct{}, 1),
		release: make(chan struct{}),
	}
	sess := &fakeSession{
		// One assigned job, then the fake blocks on GetMessage (no cancel) so the
		// loop stays alive while the reaper ticks.
		messages: []*scaleset.RunnerScaleSetMessage{
			msgWithAssigned(1, 1, assigned(1, "held")),
		},
		// no cancel: GetMessage returns ctx.Err() only once ctx is cancelled.
	}
	reaper := &recordingReaper{}
	l := New(sess, &recordingMinter{config: "jit"}, probe,
		Config{Image: "img", Reaper: reaper, ReapInterval: 20 * time.Millisecond})

	done := make(chan struct{})
	go func() { _ = l.Listen(ctx); close(done) }()

	// Wait for several reaper ticks to accumulate.
	deadline := time.After(2 * time.Second)
	for reaper.sweepCount() < 3 {
		select {
		case <-deadline:
			t.Fatalf("expected >=3 periodic sweeps, got %d", reaper.sweepCount())
		case <-time.After(5 * time.Millisecond):
		}
	}
	close(probe.release)
	cancel()
	<-done
}

// --- #103 auto-size pool from device count ------------------------------------

// stubDetector is an injectable host-capacity detector: it returns a scripted
// device count (and optional error) so pool auto-sizing can be unit-tested
// without real hardware.
type stubDetector struct {
	count int
	err   error
}

func (s stubDetector) DetectDevices() (int, error) { return s.count, s.err }

// The pool bound must be DERIVED from the detected device count when a detector
// is supplied and no explicit MaxRunners overrides it. A stub reporting 4
// devices yields a bound of 4 -- proven by offering the full bound on the first
// poll and capping concurrency at 4.
func TestPoolBoundDerivedFromDeviceCount(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	sess := &fakeSession{messages: nil, cancel: cancel}
	l := New(sess, &recordingMinter{config: "jit"}, &recordingProvisioner{},
		Config{Image: "img", DeviceDetector: stubDetector{count: 4}})

	_ = l.Listen(ctx)

	if len(sess.reportedCap) < 1 {
		t.Fatal("no GetMessage call recorded")
	}
	if sess.reportedCap[0] != 4 {
		t.Errorf("auto-sized bound: first poll offered %d, want 4 (detected devices)", sess.reportedCap[0])
	}
}

// An explicit MaxRunners must OVERRIDE detection (operator override wins over
// auto-sizing).
func TestExplicitMaxRunnersOverridesDetection(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	sess := &fakeSession{messages: nil, cancel: cancel}
	l := New(sess, &recordingMinter{config: "jit"}, &recordingProvisioner{},
		Config{Image: "img", MaxRunners: 2, DeviceDetector: stubDetector{count: 8}})

	_ = l.Listen(ctx)

	if sess.reportedCap[0] != 2 {
		t.Errorf("explicit MaxRunners must override detection: got %d want 2", sess.reportedCap[0])
	}
}

// When detection is unavailable (errors) and no MaxRunners is set, the bound
// falls back to the sane default rather than zero/unbounded.
func TestDetectionFailureFallsBackToDefault(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	sess := &fakeSession{messages: nil, cancel: cancel}
	l := New(sess, &recordingMinter{config: "jit"}, &recordingProvisioner{},
		Config{Image: "img", DeviceDetector: stubDetector{err: errors.New("no devices")}})

	_ = l.Listen(ctx)

	if sess.reportedCap[0] != defaultPoolBound {
		t.Errorf("detection failure: bound %d, want defaultPoolBound %d", sess.reportedCap[0], defaultPoolBound)
	}
}

// A detector reporting zero devices (or a negative count) also falls back to
// the default -- a bound of zero would offer no capacity and never run a job.
func TestZeroDeviceCountFallsBackToDefault(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	sess := &fakeSession{messages: nil, cancel: cancel}
	l := New(sess, &recordingMinter{config: "jit"}, &recordingProvisioner{},
		Config{Image: "img", DeviceDetector: stubDetector{count: 0}})

	_ = l.Listen(ctx)

	if sess.reportedCap[0] != defaultPoolBound {
		t.Errorf("zero device count: bound %d, want defaultPoolBound %d", sess.reportedCap[0], defaultPoolBound)
	}
}

// --- #102 locally-derived capacity --------------------------------------------

// Capacity must be derived from the LOCAL in-flight count (pool bound minus
// running jobs), NOT the server's TotalAssignedJobs. With bound=3 and one job
// held mid-flight, the next poll must report 2 (3-1); once the job finishes the
// poll reports the full 3 again -- the reported value tracks local occupancy.
func TestCapacityIsPoolBoundMinusLocalInFlight(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	// The server statistic is deliberately a large, unrelated number: if the
	// listener still derived capacity from TotalAssignedJobs it would report
	// bound-99 (clamped to 0), not bound-inflight.
	sess := &fakeSession{
		messages: []*scaleset.RunnerScaleSetMessage{
			msgWithAssigned(1, 99, assigned(1, "held")),
		},
		cancel: cancel,
	}
	probe := &concurrencyProbe{
		started: make(chan struct{}, 1),
		release: make(chan struct{}),
	}
	l := New(sess, &recordingMinter{config: "jit"}, probe, Config{Image: "img", MaxRunners: 3})

	done := make(chan struct{})
	go func() { _ = l.Listen(ctx); close(done) }()

	// Wait until the one job is mid-flight, so a subsequent poll sees inflight=1.
	select {
	case <-probe.started:
	case <-time.After(2 * time.Second):
		t.Fatal("job never started")
	}

	// Poll the reported-capacity history until a value of 2 (3-1) appears while
	// the job is held -- proving capacity = bound - local in-flight, not derived
	// from the server's TotalAssignedJobs=99 (which would clamp to 0).
	sawHeld := false
	for i := 0; i < 200; i++ {
		sess.mu.Lock()
		caps := append([]int(nil), sess.reportedCap...)
		sess.mu.Unlock()
		for _, c := range caps {
			if c == 2 {
				sawHeld = true
			}
			if c < 0 || c > 3 {
				t.Fatalf("reported capacity %d outside [0,bound=3]", c)
			}
		}
		if sawHeld {
			break
		}
		time.Sleep(5 * time.Millisecond)
	}
	if !sawHeld {
		t.Fatal("never reported capacity 2 (bound 3 - 1 in-flight) while a job was held")
	}

	// Release the job; capacity must climb back to the full bound (3) once the
	// in-flight count drops.
	close(probe.release)
	sawFull := false
	for i := 0; i < 200; i++ {
		sess.mu.Lock()
		caps := append([]int(nil), sess.reportedCap...)
		sess.mu.Unlock()
		for _, c := range caps {
			if c == 3 {
				sawFull = true
			}
		}
		if sawFull {
			break
		}
		time.Sleep(5 * time.Millisecond)
	}
	cancel()
	<-done
	if !sawFull {
		t.Fatal("capacity never returned to the full bound after the job finished")
	}
}

// Capacity arithmetic: never negative, never above the bound, regardless of
// in-flight count. A pure unit check on the helper.
func TestCapacityClampedToPoolBound(t *testing.T) {
	l := New(&fakeSession{}, &recordingMinter{}, &recordingProvisioner{}, Config{MaxRunners: 4})
	cases := []struct {
		inflight, want int
	}{
		{0, 4},
		{1, 3},
		{4, 0},
		{5, 0}, // over-subscribed -> clamp at 0, never negative
	}
	for _, c := range cases {
		if got := l.capacityFor(c.inflight); got != c.want {
			t.Errorf("capacityFor(%d) = %d, want %d", c.inflight, got, c.want)
		}
	}
}

// --- #101 bounded worker pool -------------------------------------------------

// concurrencyProbe is a provisioner that records the peak number of jobs
// running at the same time, so a test can prove jobs run concurrently AND that
// the concurrency never exceeds the pool bound. Each Provision bumps a live
// counter on entry, records the peak, blocks until released, then decrements.
type concurrencyProbe struct {
	mu      sync.Mutex
	live    int           // jobs currently inside Provision
	peak    int           // max live ever observed
	done    int           // jobs that completed
	started chan struct{} // signalled (buffered) each time a Provision begins
	release chan struct{} // Provision blocks until this is closed
}

func (p *concurrencyProbe) Provision(_ context.Context, _ ProvisionRequest) error {
	p.mu.Lock()
	p.live++
	if p.live > p.peak {
		p.peak = p.live
	}
	p.mu.Unlock()
	if p.started != nil {
		p.started <- struct{}{}
	}
	if p.release != nil {
		<-p.release
	}
	p.mu.Lock()
	p.live--
	p.done++
	p.mu.Unlock()
	return nil
}

func (p *concurrencyProbe) peakLive() int {
	p.mu.Lock()
	defer p.mu.Unlock()
	return p.peak
}

func (p *concurrencyProbe) doneCount() int {
	p.mu.Lock()
	defer p.mu.Unlock()
	return p.done
}

// The listen loop must NOT block on a single job for its whole duration: while
// a slow job is mid-provision, the loop must keep long-polling and dispatch the
// next message's job. A blocking probe holds the first job; the second message
// must still be delivered and its job dispatched before the first finishes.
func TestLoopKeepsPollingWhileJobsRun(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	sess := &fakeSession{
		messages: []*scaleset.RunnerScaleSetMessage{
			msgWithAssigned(1, 1, assigned(1, "slow-1")),
			msgWithAssigned(2, 1, assigned(2, "slow-2")),
		},
		cancel: cancel,
	}
	probe := &concurrencyProbe{
		started: make(chan struct{}, 2),
		release: make(chan struct{}),
	}
	l := New(sess, &recordingMinter{config: "jit"}, probe, Config{Image: "img", MaxRunners: 4})

	done := make(chan struct{})
	go func() { _ = l.Listen(ctx); close(done) }()

	// Both jobs must START before either is released -- proving the loop did not
	// block on slow-1 before dispatching slow-2.
	for i := 0; i < 2; i++ {
		select {
		case <-probe.started:
		case <-time.After(2 * time.Second):
			t.Fatalf("only %d of 2 jobs started; the loop blocked on an in-flight job", i)
		}
	}
	if got := probe.peakLive(); got < 2 {
		t.Fatalf("expected >=2 jobs running concurrently, peak was %d", got)
	}

	close(probe.release)
	cancel()
	<-done
}

// The pool must be BOUNDED: with a bound of 2 and three jobs offered at once,
// no more than 2 run simultaneously. The third waits for a slot.
func TestPoolBoundCapsConcurrency(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	sess := &fakeSession{
		messages: []*scaleset.RunnerScaleSetMessage{
			msgWithAssigned(1, 3,
				assigned(1, "a"), assigned(2, "b"), assigned(3, "c")),
		},
		cancel: cancel,
	}
	probe := &concurrencyProbe{
		started: make(chan struct{}, 3),
		release: make(chan struct{}),
	}
	l := New(sess, &recordingMinter{config: "jit"}, probe, Config{Image: "img", MaxRunners: 2})

	done := make(chan struct{})
	go func() { _ = l.Listen(ctx); close(done) }()

	// Exactly 2 jobs may start while the slot-holders are blocked; the 3rd must
	// wait. Drain 2 starts, then assert no 3rd arrives until we release.
	for i := 0; i < 2; i++ {
		select {
		case <-probe.started:
		case <-time.After(2 * time.Second):
			t.Fatalf("only %d of 2 jobs started under bound=2", i)
		}
	}
	select {
	case <-probe.started:
		t.Fatal("a 3rd job started while the bound is 2 (semaphore not enforced)")
	case <-time.After(150 * time.Millisecond):
		// good -- the 3rd job is parked waiting for a slot.
	}
	if got := probe.peakLive(); got > 2 {
		t.Fatalf("concurrency exceeded the bound of 2: peak %d", got)
	}

	close(probe.release)
	cancel()
	<-done
}

// Clean shutdown must WAIT for in-flight jobs: when the context is cancelled
// while a job is still running, Listen must not return until that job's
// Provision has completed (no orphaned goroutines, no torn-down session under a
// running container).
func TestCleanShutdownWaitsForInFlightJobs(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	sess := &fakeSession{
		messages: []*scaleset.RunnerScaleSetMessage{
			msgWithAssigned(1, 1, assigned(1, "long")),
		},
		cancel: cancel,
	}
	probe := &concurrencyProbe{
		started: make(chan struct{}, 1),
		release: make(chan struct{}),
	}
	l := New(sess, &recordingMinter{config: "jit"}, probe, Config{Image: "img", MaxRunners: 2})

	done := make(chan struct{})
	go func() { _ = l.Listen(ctx); close(done) }()

	// Wait for the job to be mid-flight, then cancel.
	select {
	case <-probe.started:
	case <-time.After(2 * time.Second):
		t.Fatal("job never started")
	}
	cancel()

	// Listen must NOT have returned yet -- the in-flight job is still blocked.
	select {
	case <-done:
		t.Fatal("Listen returned before the in-flight job finished (no drain)")
	case <-time.After(100 * time.Millisecond):
	}

	// Release the job; now Listen must wind down and the job must have completed.
	close(probe.release)
	select {
	case <-done:
	case <-time.After(2 * time.Second):
		t.Fatal("Listen did not return after the in-flight job finished")
	}
	if probe.doneCount() != 1 {
		t.Fatalf("expected the in-flight job to complete on drain, done=%d", probe.doneCount())
	}
	if !sess.closed {
		t.Error("session must still be torn down after the drain")
	}
}

// --- #138 JobID canonicalization (tracked-set vs sanitized container label) ----

// gateReaper records the tracked ids from the FIRST sweep that observes a
// non-empty tracked set (i.e. the first sweep after a job is in-flight),
// signalling so the test knows that sweep ran. Earlier startup sweeps (before
// any job is tracked) are skipped so the assertion is about the in-flight job.
type gateReaper struct {
	mu    sync.Mutex
	first []string
	fired chan struct{} // closed once the first non-empty sweep is captured
	once  sync.Once
}

func (r *gateReaper) Reap(_ context.Context, tracked []string) error {
	if len(tracked) == 0 {
		return nil // a pre-job startup sweep: nothing in-flight yet
	}
	r.once.Do(func() {
		r.mu.Lock()
		r.first = append([]string(nil), tracked...)
		r.mu.Unlock()
		close(r.fired)
	})
	return nil
}

func (r *gateReaper) firstSweep() []string {
	r.mu.Lock()
	defer r.mu.Unlock()
	return append([]string(nil), r.first...)
}

// A JobID carrying a control char (here a TAB) must reach the reaper in the
// SAME canonical form the container's sanitized job-id label carries
// (lib/runner-container.sh runner_job_id_label = `tr -d '[:cntrl:]'`).
// Otherwise the reaper's exact-string compare (lib/runner-reaper.sh
// _runner_reaper_is_tracked) treats the live job's own container as an orphan
// and rm -f's it mid-run (#138). The Go tracked set, the script argv, and the
// resulting label must all derive from one identical sanitized string, so the
// id the reaper is handed for an IN-FLIGHT job must equal the control-char-
// stripped JobID -- never the raw one.
func TestTrackedJobIDIsSanitizedToMatchContainerLabel(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	const rawJobID = "job\tA"  // attacker-influenced control char
	const wantTracked = "jobA" // what runner_job_id_label strips it to (the label)

	// A provisioner that blocks the single job keeps it IN-FLIGHT (tracked)
	// across the reaper sweep.
	probe := &concurrencyProbe{
		started: make(chan struct{}, 1),
		release: make(chan struct{}),
	}
	sess := &fakeSession{
		messages: []*scaleset.RunnerScaleSetMessage{
			msgWithAssigned(1, 1, assigned(1, rawJobID)),
		},
		// no cancel: the loop stays alive while the job is held and the reaper ticks.
	}
	reaper := &gateReaper{fired: make(chan struct{})}
	l := New(sess, &recordingMinter{config: "jit"}, probe,
		Config{Image: "img", Reaper: reaper, ReapInterval: 10 * time.Millisecond})

	done := make(chan struct{})
	go func() { _ = l.Listen(ctx); close(done) }()

	// Wait for the held job to be in-flight (tracked) before the sweep matters.
	select {
	case <-probe.started:
	case <-time.After(2 * time.Second):
		t.Fatal("provisioner never started the held job")
	}

	// Wait for the reaper's first sweep while the job is held in-flight.
	select {
	case <-reaper.fired:
	case <-time.After(2 * time.Second):
		t.Fatal("reaper never swept while the job was in-flight")
	}

	tracked := reaper.firstSweep()
	if len(tracked) != 1 {
		t.Fatalf("expected exactly 1 tracked id during the in-flight sweep, got %v", tracked)
	}
	if tracked[0] != wantTracked {
		t.Errorf("tracked id handed to reaper = %q, want %q (the sanitized job-id label); "+
			"a raw control-char key %q != the container label desyncs and the reaper reaps the live job (#138)",
			tracked[0], wantTracked, rawJobID)
	}

	// Wind the held job down so Listen can return.
	close(probe.release)
	cancel()
	select {
	case <-done:
	case <-time.After(2 * time.Second):
		t.Fatal("Listen did not return after the held job was released")
	}
}
