package listener

import (
	"context"
	"errors"
	"testing"

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
	messages       []*scaleset.RunnerScaleSetMessage // scripted, drained front-to-back
	getErr         error                             // returned once messages are drained
	reportedCap    []int                             // maxCapacity passed to each GetMessage
	deletedIDs     []int                             // messageIDs acked via DeleteMessage
	acquiredReqIDs [][]int64                         // requestIDs passed to each AcquireJobs
	closed         bool                              // Close was called (teardown)
}

func (f *fakeSession) GetMessage(_ context.Context, _ int, maxCapacity int) (*scaleset.RunnerScaleSetMessage, error) {
	f.reportedCap = append(f.reportedCap, maxCapacity)
	if len(f.messages) == 0 {
		if f.getErr != nil {
			return nil, f.getErr
		}
		return nil, errDrained
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
	f.deletedIDs = append(f.deletedIDs, messageID)
	return nil
}

func (f *fakeSession) Session() scaleset.RunnerScaleSetSession {
	return scaleset.RunnerScaleSetSession{}
}

func (f *fakeSession) Close(_ context.Context) error {
	f.closed = true
	return nil
}

// errDrained ends the loop cleanly once the scripted messages are exhausted,
// standing in for "the test is done" rather than a real session error.
var errDrained = errors.New("drained")

// recordingProvisioner is a mock of the per-job container provisioner glue.
// It records every job it was asked to provision (so a test can assert an
// ASSIGNED job triggered the shell-out, and with which JIT config), and can be
// told to fail to exercise the error path.
type recordingProvisioner struct {
	jobs    []ProvisionRequest
	failOn  string // RequestID-bearing JobID to fail; "" never fails
	failErr error
}

func (r *recordingProvisioner) Provision(_ context.Context, req ProvisionRequest) error {
	r.jobs = append(r.jobs, req)
	if r.failErr != nil {
		return r.failErr
	}
	return nil
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
	sess := &fakeSession{
		messages: []*scaleset.RunnerScaleSetMessage{
			msgWithAssigned(1, 1, assigned(42, "job-abc", "gpu")),
		},
	}
	prov := &recordingProvisioner{}
	l := New(sess, prov, Config{Image: "ghcr.io/acme/runner:latest"})

	if err := l.Listen(context.Background()); err != nil && !errors.Is(err, errDrained) {
		t.Fatalf("Listen returned unexpected error: %v", err)
	}
	if len(prov.jobs) != 1 {
		t.Fatalf("expected exactly 1 provisioned job, got %d", len(prov.jobs))
	}
	got := prov.jobs[0]
	if got.JobID != "job-abc" {
		t.Errorf("provisioned wrong job: got %q want %q", got.JobID, "job-abc")
	}
	if got.EncodedJITConfig == "" {
		t.Error("expected a JIT config to be passed through to the provisioner, got empty")
	}
	if got.Image != "ghcr.io/acme/runner:latest" {
		t.Errorf("provisioner got wrong image: %q", got.Image)
	}
}

// Reported capacity must FOLLOW demand: the listener tells the session how many
// runners it can serve via maxCapacity, derived from the session's
// TotalAssignedJobs statistic so GitHub never assigns beyond what we provision.
func TestReportedCapacityFollowsDemand(t *testing.T) {
	sess := &fakeSession{
		messages: []*scaleset.RunnerScaleSetMessage{
			msgWithAssigned(1, 3, assigned(1, "j1")),
		},
	}
	prov := &recordingProvisioner{}
	l := New(sess, prov, Config{Image: "img", MaxRunners: 5})

	_ = l.Listen(context.Background())

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
	sess := &fakeSession{
		messages: []*scaleset.RunnerScaleSetMessage{
			msgWithAssigned(7, 1, assigned(1, "j1")),
		},
	}
	prov := &recordingProvisioner{}
	l := New(sess, prov, Config{Image: "img"})

	_ = l.Listen(context.Background())

	if len(sess.deletedIDs) != 1 || sess.deletedIDs[0] != 7 {
		t.Errorf("expected message 7 to be acked, got %v", sess.deletedIDs)
	}
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
	l := New(sess, prov, Config{Image: "img"})

	err := l.Listen(context.Background())
	if !errors.Is(err, wantErr) {
		t.Errorf("expected the provisioner error to surface, got %v", err)
	}
	if !sess.closed {
		t.Error("expected the session to be torn down (Close) on the error path")
	}
}

// A clean drain (session has no more messages) must still tear the session
// down -- the normal teardown path, not just the error path.
func TestSessionTornDownOnCleanExit(t *testing.T) {
	sess := &fakeSession{messages: nil, getErr: errDrained}
	prov := &recordingProvisioner{}
	l := New(sess, prov, Config{Image: "img"})

	_ = l.Listen(context.Background())

	if !sess.closed {
		t.Error("expected the session to be torn down (Close) on a clean exit")
	}
}

// A message that carries an available-but-not-assigned job (no JobAssigned
// entries) must NOT shell out -- only ASSIGNED jobs get a container, since
// only those are ours to run. Guards against over-provisioning on availability.
func TestAvailableButUnassignedDoesNotProvision(t *testing.T) {
	sess := &fakeSession{
		messages: []*scaleset.RunnerScaleSetMessage{
			msgWithAssigned(1, 0 /* no assigned jobs */),
		},
	}
	prov := &recordingProvisioner{}
	l := New(sess, prov, Config{Image: "img"})

	_ = l.Listen(context.Background())

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
