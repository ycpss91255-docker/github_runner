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
	f.reportedCap = append(f.reportedCap, maxCapacity)
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
	l := New(sess, minter, prov, Config{Image: "ghcr.io/acme/runner:latest"})

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
}

// Reported capacity must FOLLOW demand: the listener tells the session how many
// runners it can serve via maxCapacity, derived from the session's
// TotalAssignedJobs statistic so GitHub never assigns beyond what we provision.
func TestReportedCapacityFollowsDemand(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	sess := &fakeSession{
		messages: []*scaleset.RunnerScaleSetMessage{
			msgWithAssigned(1, 3, assigned(1, "j1")),
		},
		cancel: cancel,
	}
	prov := &recordingProvisioner{}
	l := New(sess, &recordingMinter{config: "jit"}, prov, Config{Image: "img", MaxRunners: 5})

	_ = l.Listen(ctx)

	if len(sess.reportedCap) < 2 {
		t.Fatalf("expected at least 2 GetMessage calls (initial + post-demand), got %d", len(sess.reportedCap))
	}
	// First poll: no demand seen yet, capacity is the full ceiling.
	if sess.reportedCap[0] != 5 {
		t.Errorf("initial capacity: got %d want 5 (MaxRunners)", sess.reportedCap[0])
	}
	// After a message reporting TotalAssignedJobs=3, the next poll must request
	// the remaining headroom (5 ceiling - 3 assigned = 2), so capacity follows
	// demand rather than blindly re-offering the full ceiling.
	if sess.reportedCap[1] != 2 {
		t.Errorf("capacity after demand=3: got %d want 2 (5-3)", sess.reportedCap[1])
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
