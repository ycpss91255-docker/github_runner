package listener

import (
	"context"
	"errors"
	"sync"
	"testing"
	"time"

	"github.com/actions/scaleset"
)

// errContainerExit is a plain (non-*exec.ExitError) failure: a job that failed
// without a clean container exit code, so its structured exit status is -1.
var errContainerExit = errors.New("container exited")

// fakeJobLogger is a recording stand-in for the structured-logging seam (#131):
// it captures every per-job record and every capacity snapshot the listener
// emits, race-free, so a test can assert the structured fields without parsing
// journald output.
type fakeJobLogger struct {
	mu       sync.Mutex
	jobs     []JobRecord
	capacity []CapacityRecord
}

func (f *fakeJobLogger) JobCompleted(rec JobRecord) {
	f.mu.Lock()
	f.jobs = append(f.jobs, rec)
	f.mu.Unlock()
}

func (f *fakeJobLogger) CapacityReport(rec CapacityRecord) {
	f.mu.Lock()
	f.capacity = append(f.capacity, rec)
	f.mu.Unlock()
}

func (f *fakeJobLogger) jobRecords() []JobRecord {
	f.mu.Lock()
	defer f.mu.Unlock()
	return append([]JobRecord(nil), f.jobs...)
}

func (f *fakeJobLogger) capacityRecords() []CapacityRecord {
	f.mu.Lock()
	defer f.mu.Unlock()
	return append([]CapacityRecord(nil), f.capacity...)
}

// A finished job must emit ONE structured record carrying its id, image, exit
// status (0 on success) and a non-negative duration (#131).
func TestJobCompletedLogsStructuredFields(t *testing.T) {
	jl := &fakeJobLogger{}
	sess := &fakeSession{messages: []*scaleset.RunnerScaleSetMessage{
		msgWithAssigned(1, 1, assigned(11, "job-log")),
	}}
	ctx, cancel := context.WithCancel(context.Background())
	sess.cancel = cancel

	l := New(sess, &recordingMinter{config: "jit"}, &recordingProvisioner{},
		Config{Image: "ghcr.io/acme/runner:1.0", JobLogger: jl})
	_ = l.Listen(ctx)

	recs := jl.jobRecords()
	if len(recs) != 1 {
		t.Fatalf("got %d job records, want 1: %+v", len(recs), recs)
	}
	r := recs[0]
	if r.JobID != "job-log" {
		t.Errorf("JobID: got %q want %q", r.JobID, "job-log")
	}
	if r.Image != "ghcr.io/acme/runner:1.0" {
		t.Errorf("Image: got %q want the configured image", r.Image)
	}
	if r.Exit != 0 {
		t.Errorf("Exit: got %d want 0 (success)", r.Exit)
	}
	if r.Duration < 0 {
		t.Errorf("Duration: got %v want non-negative", r.Duration)
	}
}

// A failed job (the provisioner returned an error not carrying a clean exit
// code) must still be logged, with a non-zero exit status so the structured
// record reflects the failure (#131).
func TestJobCompletedLogsNonZeroExitOnFailure(t *testing.T) {
	jl := &fakeJobLogger{}
	prov := &recordingProvisioner{failErr: errContainerExit}
	sess := &fakeSession{messages: []*scaleset.RunnerScaleSetMessage{
		msgWithAssigned(1, 1, assigned(11, "job-bad")),
	}}
	ctx, cancel := context.WithCancel(context.Background())
	sess.cancel = cancel

	l := New(sess, &recordingMinter{config: "jit"}, prov,
		Config{Image: "img", JobLogger: jl,
			OnJobErr: func(ProvisionRequest, error) {}})
	_ = l.Listen(ctx)

	recs := jl.jobRecords()
	if len(recs) != 1 {
		t.Fatalf("got %d job records, want 1", len(recs))
	}
	if recs[0].Exit == 0 {
		t.Errorf("Exit: got 0 want non-zero for a failed job")
	}
}

// The capacity/in-flight snapshot must be emitted periodically (#131): with a
// short interval and a blocking job in-flight, at least one snapshot must report
// the in-flight job and the reduced spare capacity.
func TestCapacityReportedPeriodically(t *testing.T) {
	jl := &fakeJobLogger{}
	block := make(chan struct{})
	started := make(chan struct{}, 1)
	prov := &recordingProvisioner{started: started, block: block}

	sess := &fakeSession{messages: []*scaleset.RunnerScaleSetMessage{
		msgWithAssigned(1, 1, assigned(11, "job-cap")),
	}}
	// Keep the loop alive (no cancel-on-drain) so the reporter keeps ticking;
	// the test cancels explicitly once it has observed a snapshot.
	ctx, cancel := context.WithCancel(context.Background())

	l := New(sess, &recordingMinter{config: "jit"}, prov,
		Config{Image: "img", MaxRunners: 2, JobLogger: jl,
			CapacityReportInterval: 5 * time.Millisecond})

	done := make(chan struct{})
	go func() { _ = l.Listen(ctx); close(done) }()

	// Wait for the job to be in-flight (it blocks), so a snapshot taken now sees
	// exactly one in-flight slot against the bound of 2.
	<-started

	// Poll for a snapshot that observed the in-flight job.
	deadline := time.After(2 * time.Second)
	var sawInFlight bool
	for !sawInFlight {
		select {
		case <-deadline:
			t.Fatal("no capacity snapshot observed the in-flight job in time")
		default:
		}
		for _, c := range jl.capacityRecords() {
			if c.Bound == 2 && c.InFlight == 1 && c.Capacity == 1 {
				sawInFlight = true
				break
			}
		}
		time.Sleep(2 * time.Millisecond)
	}

	close(block) // let the job finish
	cancel()
	<-done
}
