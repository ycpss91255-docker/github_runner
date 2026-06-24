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
	if r.failErr != nil {
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

// A failing provisioner (e.g. the container shell-out returns non-zero) must
// surface as a Listen error, and the session must still be torn down (Close)
// so a crashed job does not strand the scale-set session.
func TestProvisionerErrorIsSurfacedAndSessionTornDown(t *testing.T) {
	sess := &fakeSession{
		messages: []*scaleset.RunnerScaleSetMessage{
			msgWithAssigned(1, 1, assigned(1, "boom")),
		},
	}
	wantErr := errors.New("container exited 1")
	prov := &recordingProvisioner{failErr: wantErr}
	l := New(sess, &recordingMinter{config: "jit"}, prov, Config{Image: "img"})

	err := l.Listen(context.Background())
	if !errors.Is(err, wantErr) {
		t.Errorf("expected the provisioner error to surface, got %v", err)
	}
	if !sess.closed {
		t.Error("expected the session to be torn down (Close) on the error path")
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
