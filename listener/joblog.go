package listener

import (
	"errors"
	"log/slog"
	"os"
	"os/exec"
	"time"
)

// JobLogger is the structured-logging seam for the ephemeral path (#131). The
// listener emits one structured record per finished job (id, image, exit,
// duration) and a periodic capacity/in-flight snapshot through it, so an
// operator can audit per-job outcomes and live headroom from the journal. It is
// an interface so production wires the journald-friendly slog logger
// (NewJournalJobLogger) while tests inject a recording fake and assert the
// fields. A nil JobLogger disables structured logging (the listener falls back
// to its plain log.Printf lines).
type JobLogger interface {
	// JobCompleted records the outcome of one finished ephemeral job.
	JobCompleted(rec JobRecord)
	// CapacityReport records a periodic snapshot of pool occupancy.
	CapacityReport(rec CapacityRecord)
}

// JobRecord is the structured per-job log record (#131): the job's identity, the
// image it ran in, its container exit status, and how long it took. It is what
// the listener knows about a finished ephemeral job, emitted once per job.
type JobRecord struct {
	JobID    string        // GitHub job id
	Image    string        // container image the job ran in
	Exit     int           // container exit status (0 = success)
	Duration time.Duration // wall-clock provisioning time
}

// CapacityRecord is the periodic capacity/in-flight snapshot (#131): the pool
// bound, how many jobs are in-flight right now, and the spare capacity reported
// to GitHub. Emitted on an interval so live occupancy is observable.
type CapacityRecord struct {
	Bound    int // worker-pool ceiling
	InFlight int // jobs currently being provisioned
	Capacity int // spare capacity offered to GitHub (bound - inFlight)
}

// slogJobLogger is the production JobLogger: it emits structured records via
// log/slog. Under a systemd unit the process's stderr is captured by journald,
// so these key=value records land in the journal (the ephemeral path's audit
// sink) with stable field names for later querying.
type slogJobLogger struct {
	log *slog.Logger
}

// NewJournalJobLogger builds the production JobLogger emitting structured slog
// records to stderr -- which journald captures when the listener runs as a
// systemd unit (#131). Records carry a stable "component=listener" field so they
// are filterable in the journal. A nil base falls back to a default stderr
// text handler.
func NewJournalJobLogger() JobLogger {
	h := slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{})
	return &slogJobLogger{log: slog.New(h).With("component", "listener")}
}

func (s *slogJobLogger) JobCompleted(rec JobRecord) {
	s.log.Info("job completed",
		"event", "job_completed",
		"job_id", rec.JobID,
		"image", rec.Image,
		"exit", rec.Exit,
		"duration_ms", rec.Duration.Milliseconds(),
	)
}

func (s *slogJobLogger) CapacityReport(rec CapacityRecord) {
	s.log.Info("capacity report",
		"event", "capacity_report",
		"bound", rec.Bound,
		"in_flight", rec.InFlight,
		"capacity", rec.Capacity,
	)
}

// exitCodeFromErr maps a Provision result into a structured exit status (#131):
// nil -> 0 (success); an *exec.ExitError (a non-zero container exit propagated
// by the bash provisioner) -> its code; any other non-nil error -> -1 (the job
// failed before/around the container without a clean exit code).
func exitCodeFromErr(err error) int {
	if err == nil {
		return 0
	}
	var ee *exec.ExitError
	if errors.As(err, &ee) {
		return ee.ExitCode()
	}
	return -1
}
