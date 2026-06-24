// Package listener is the provisioning glue between the official Runner Scale
// Set Client (github.com/actions/scaleset, ADR-0001 Phase 4) and the per-job
// container provisioner (lib/runner-container.sh, Phase 3). The GitHub client
// owns the outbound long-poll scale-set session protocol; this package owns
// only the glue: it reads demand (Statistics.TotalAssignedJobs) off each
// message, and for every ASSIGNED job it shells out to the Phase 3 provisioner
// to run that job in a fresh, single-use, rootless container. It decides
// nothing about *when / how many* runners (that is the scale set's job) -- it
// supplies the isolation the scale set client does not.
package listener

import (
	"context"
	"log"
	"sync"
	"sync/atomic"
	"time"

	"github.com/actions/scaleset"
)

// defaultReapInterval is how often the periodic orphan sweep runs (#105) when
// a Reaper is configured but no interval is set.
const defaultReapInterval = 5 * time.Minute

// defaultPoolBound is the worker-pool ceiling used when no MaxRunners is
// configured -- a sane, conservative concurrency default so an unconfigured
// listener still bounds in-flight jobs rather than spawning unboundedly.
const defaultPoolBound = 1

// Session is the subset of the official scale-set message session
// (*scaleset.MessageSessionClient) the listener drives. Defining it as an
// interface here -- rather than taking the concrete client -- is the seam that
// makes the loop unit-testable without a live GitHub scale set: tests inject a
// fake, production injects the real client. The compile-time assertion below
// proves the real client satisfies it, so the two are interchangeable.
type Session interface {
	// GetMessage long-polls for the next scale-set message, reporting the
	// listener's current spare capacity (maxCapacity) so GitHub never assigns
	// more jobs than we can provision.
	GetMessage(ctx context.Context, lastMessageID int, maxCapacity int) (*scaleset.RunnerScaleSetMessage, error)
	// AcquireJobs claims the given request IDs for this session (the JIT
	// configs for those jobs become ours to run).
	AcquireJobs(ctx context.Context, requestIDs []int64) ([]int64, error)
	// DeleteMessage acks a processed message so the long-poll does not
	// redeliver it.
	DeleteMessage(ctx context.Context, messageID int) error
	// Session returns the current session metadata (id, scale set, statistics).
	Session() scaleset.RunnerScaleSetSession
	// Close tears the session down -- always called when the loop exits, clean
	// or error, so a crashed job never strands the scale-set session.
	Close(ctx context.Context) error
}

// The official client must be drop-in for the Session seam, so production can
// hand a *scaleset.MessageSessionClient straight into New.
var _ Session = (*scaleset.MessageSessionClient)(nil)

// ProvisionRequest is everything the per-job container provisioner needs to run
// exactly one ephemeral job: the single-use JIT config minted for it, the
// container image to run it in, and the job's identity (for logging / the
// runner dir name). It is the in-Go shape of the arguments the Phase 3
// runner_container_run shell seam consumes.
type ProvisionRequest struct {
	JobID            string   // GitHub job id (assigned message JobID)
	RequestID        int64    // scale-set runner request id (for AcquireJobs)
	Labels           []string // the job's requested labels
	EncodedJITConfig string   // single-use server-minted JIT config for this job
	Image            string   // container image to run the job in
}

// Provisioner runs one ephemeral job in a throwaway container. The production
// implementation (ContainerProvisioner) shells out to lib/runner-container.sh;
// tests inject a recording mock. Provision returns the job's error (a non-zero
// container exit) so the listener can surface it and tear down.
type Provisioner interface {
	Provision(ctx context.Context, req ProvisionRequest) error
}

// JITConfigMinter mints the single-use, server-side JIT config a given runner
// consumes once (`run.sh --jitconfig <encoded>`) and then de-registers. The
// production implementation (ClientJITMinter, wired in main.go) calls the
// scale-set Go client's GenerateJitRunnerConfig -- a method on *Client, not on
// the message session -- so it is injected here as its own seam, mirroring the
// Session / Provisioner pattern, and mocked in tests. ADR-0001/ADR-0003 put
// minting on the Go side of the boundary; nothing in bash mints any more.
type JITConfigMinter interface {
	// Mint returns the encoded JIT config for a runner named name with the
	// given labels (the job's requested labels).
	Mint(ctx context.Context, name string, labels []string) (string, error)
}

// Reaper sweeps orphaned containers no longer tracked by the listener (#105),
// keyed by the managed-by label. The production implementation shells out to
// the bash reaper (lib/runner-reaper.sh, ADR-0003: reaping is bash's job); the
// listener invokes it on startup and on an interval, passing the job ids it is
// currently tracking so their live containers are spared. Tests inject a fake.
type Reaper interface {
	// Reap removes labelled containers whose job id is NOT in tracked.
	Reap(ctx context.Context, tracked []string) error
}

// DeviceDetector reports how many host devices (e.g. GPUs) are available, so
// the worker-pool bound can auto-size to hardware rather than a hardcoded
// number (#103). It is a seam: the production implementation enumerates real
// devices, tests inject a stub. DetectDevices returns the count, or an error
// when detection is unavailable (the caller then falls back to a sane default).
type DeviceDetector interface {
	DetectDevices() (int, error)
}

// Config holds the listener's static knobs.
type Config struct {
	// DeviceDetector, when set and no explicit MaxRunners overrides it,
	// auto-sizes the worker-pool bound from the detected device count (#103).
	// A detection error or a non-positive count falls back to defaultPoolBound.
	DeviceDetector DeviceDetector
	// Reaper, when set, sweeps orphaned containers on startup and on
	// ReapInterval (#105), sparing the listener's currently-tracked jobs. Nil
	// disables reaping.
	Reaper Reaper
	// ReapInterval is the periodic orphan-sweep cadence; zero falls back to
	// defaultReapInterval. Ignored when Reaper is nil.
	ReapInterval time.Duration
	// Image is the container image every ephemeral job runs in (passed to the
	// Phase 3 provisioner).
	Image string
	// MaxRunners is the worker-pool bound: the ceiling on concurrently-
	// provisioned runners and the basis for locally-derived capacity (#102 --
	// capacity reported to GitHub is this bound minus the local in-flight count).
	// Zero falls back to defaultPoolBound. When DeviceDetector is set (#103) the
	// detected device count overrides this.
	MaxRunners int
	// OnJobErr is called with a job's ProvisionRequest and the error when its
	// container exits non-zero. A per-job failure is an isolated outcome -- it
	// is reported here and the loop continues; it never ends the loop or closes
	// the session. Nil falls back to a log.Printf default.
	OnJobErr func(req ProvisionRequest, err error)
}

// Listener pairs an injected scale-set Session with a Provisioner and runs the
// demand->provision loop. Provisioning is concurrent: each acquired job runs in
// its own goroutine bounded by a worker-pool semaphore (#101), so the listen
// loop keeps long-polling instead of blocking on any single job for its whole
// duration. The pool bound is the listener's concurrency ceiling.
type Listener struct {
	session Session
	minter  JITConfigMinter
	prov    Provisioner
	cfg     Config

	bound    int           // worker-pool ceiling (max concurrent provisions)
	sem      chan struct{} // counting semaphore: one token per in-flight slot
	wg       sync.WaitGroup
	inFlight atomic.Int64 // jobs currently being provisioned (locally derived capacity, #102)

	trackedMu sync.Mutex          // guards tracked
	tracked   map[string]struct{} // job ids currently in-flight (spared by the reaper, #105)
}

// New wires a Session + JITConfigMinter + Provisioner + Config into a Listener.
// The worker-pool bound is resolved by resolveBound (explicit MaxRunners >
// auto-detected device count > defaultPoolBound), and the bounding semaphore is
// sized to it.
func New(session Session, minter JITConfigMinter, prov Provisioner, cfg Config) *Listener {
	bound := resolveBound(cfg)
	return &Listener{
		session: session,
		minter:  minter,
		prov:    prov,
		cfg:     cfg,
		bound:   bound,
		sem:     make(chan struct{}, bound),
		tracked: make(map[string]struct{}),
	}
}

// resolveBound picks the worker-pool bound with a clear precedence (#103):
//
//  1. an explicit Config.MaxRunners (> 0) -- an operator override always wins;
//  2. otherwise the auto-detected host device count, when a DeviceDetector is
//     supplied and reports a positive count;
//  3. otherwise defaultPoolBound -- the sane fallback when detection is absent,
//     errors, or reports a non-positive count (a zero bound would offer no
//     capacity and never run a job).
func resolveBound(cfg Config) int {
	if cfg.MaxRunners > 0 {
		return cfg.MaxRunners
	}
	if cfg.DeviceDetector != nil {
		if n, err := cfg.DeviceDetector.DetectDevices(); err == nil && n > 0 {
			return n
		}
	}
	return defaultPoolBound
}

// Listen runs the long-poll loop until the session drains or the context is
// done, ALWAYS tearing the session down on exit. Each iteration:
//
//  1. GetMessage, reporting LOCALLY-derived spare capacity (pool bound minus
//     the local in-flight count, #102) so reported headroom matches what THIS
//     host can actually run -- not the server's TotalAssignedJobs -- and GitHub
//     never assigns more than the pool can provision.
//  2. For every ASSIGNED job in the message, acquire it and mint its single-use
//     JIT config -- claiming the work that is ours to run.
//  3. Ack the message (DeleteMessage) so it is not redelivered. The ack lands
//     once the jobs are acquired/dispatched, BEFORE the (potentially long)
//     container run, so a slow job never leaves its message unacked.
//  4. Shell out to the per-job container provisioner for each acquired job --
//     the fresh-container isolation the scale set client does not provide. A
//     job's failure is an isolated per-job outcome (logged, loop continues).
//
// Only a genuine transport/session error (a non-context GetMessage / AcquireJobs
// / DeleteMessage failure) returns from the loop; the session is ALWAYS torn
// down on exit. Context cancellation ends the loop cleanly.
func (l *Listener) Listen(ctx context.Context) (err error) {
	// Teardown is unconditional: clean exit or mid-job failure, the session
	// must be closed so it does not linger server-side. The DRAIN (#101) runs
	// FIRST: we wait for every dispatched in-flight job to finish before closing
	// the session, so a clean shutdown never tears the session down (or returns)
	// while a container is still running.
	defer func() {
		l.wg.Wait()
		closeErr := l.session.Close(ctx)
		if err == nil {
			err = closeErr
		}
	}()

	// Startup orphan sweep (#105): clear any labelled leftovers from a previous
	// crash before we begin (nothing is tracked yet, so all are orphans), then
	// start the periodic sweep. stopReaper joins the periodic goroutine on exit.
	l.reap(ctx)
	stopReaper := l.startReaper(ctx)
	defer stopReaper()

	lastMessageID := 0

	for {
		if cerr := ctx.Err(); cerr != nil {
			return cerr
		}

		// Capacity is LOCAL: the pool bound less the jobs currently in-flight on
		// THIS host (#102). It is not the server's TotalAssignedJobs -- reported
		// headroom must reflect what we can actually run, and it updates as jobs
		// start and finish.
		capacity := l.capacityFor(int(l.inFlight.Load()))
		msg, gerr := l.session.GetMessage(ctx, lastMessageID, capacity)
		if gerr != nil {
			// The loop terminates ONLY on context cancellation (shutdown /
			// SIGTERM). Every other GetMessage error is a genuine
			// transport/session failure and is fatal -- surfaced as-is.
			return gerr
		}
		if msg == nil {
			continue
		}

		// Acquire + mint every assigned job FIRST, so the message can be acked
		// before we run any container.
		reqs, aerr := l.acquire(ctx, msg)
		if aerr != nil {
			return aerr
		}

		// Ack the message now that its jobs are acquired/dispatched -- before
		// the (potentially long) provisioning below -- so a slow job never
		// leaves the message unacked for its whole duration.
		if msg.MessageID > 0 {
			if derr := l.session.DeleteMessage(ctx, msg.MessageID); derr != nil {
				return derr
			}
			lastMessageID = msg.MessageID
		}

		// Provisioning is per-job isolated: a failed job is logged and the loop
		// carries on; it never ends Listen.
		l.provision(ctx, reqs)
	}
}

// acquire claims every ASSIGNED job in the message and mints its single-use JIT
// config, returning a ready-to-run ProvisionRequest per job. Only assigned jobs
// are ours to run; available-but-unassigned jobs are left for the scale set to
// assign, so we never over-provision on availability.
func (l *Listener) acquire(ctx context.Context, msg *scaleset.RunnerScaleSetMessage) ([]ProvisionRequest, error) {
	var reqs []ProvisionRequest
	for _, ja := range msg.JobAssignedMessages {
		if ja == nil {
			continue
		}
		// Claim the job so its JIT config is ours to run.
		if _, err := l.session.AcquireJobs(ctx, []int64{ja.RunnerRequestID}); err != nil {
			return nil, err
		}
		// Mint the single-use JIT config for this job via the Go client
		// (ADR-0001: minting lives on the Go side of the boundary).
		jit, err := l.minter.Mint(ctx, ja.JobID, ja.RequestLabels)
		if err != nil {
			return nil, err
		}
		reqs = append(reqs, ProvisionRequest{
			JobID:            ja.JobID,
			RequestID:        ja.RunnerRequestID,
			Labels:           ja.RequestLabels,
			EncodedJITConfig: jit,
			Image:            l.cfg.Image,
		})
	}
	return reqs, nil
}

// provision dispatches the per-job container for each acquired job into the
// bounded worker pool (#101): each job runs in its own goroutine, gated by the
// counting semaphore so no more than `bound` run at once. Dispatch BLOCKS only
// while every slot is taken (back-pressure) -- otherwise it returns immediately
// so the listen loop keeps long-polling. A job's failure (non-zero container
// exit) is an ISOLATED, per-job outcome: it is reported via OnJobErr and the
// other jobs are unaffected. It never ends the listen loop or closes the
// session -- only genuine transport/session errors do that. Every dispatched
// job is tracked on the WaitGroup so a clean shutdown drains them.
func (l *Listener) provision(ctx context.Context, reqs []ProvisionRequest) {
	for _, req := range reqs {
		// Acquire a worker slot (back-pressure when the pool is full). Honour
		// cancellation so shutdown does not block forever waiting for a slot.
		select {
		case l.sem <- struct{}{}:
		case <-ctx.Done():
			return
		}
		l.wg.Add(1)
		l.inFlight.Add(1)
		l.track(req.JobID)
		go func(req ProvisionRequest) {
			defer l.wg.Done()
			defer l.inFlight.Add(-1)
			defer l.untrack(req.JobID)
			defer func() { <-l.sem }()
			if err := l.prov.Provision(ctx, req); err != nil {
				l.reportJobErr(req, err)
			}
		}(req)
	}
}

// reportJobErr surfaces a per-job failure, via the injected OnJobErr hook or a
// log.Printf default.
func (l *Listener) reportJobErr(req ProvisionRequest, err error) {
	if l.cfg.OnJobErr != nil {
		l.cfg.OnJobErr(req, err)
		return
	}
	log.Printf("job %s failed (isolated, listener continues): %v", req.JobID, err)
}

// track / untrack maintain the set of in-flight job ids the reaper must spare
// (#105): a job's container is only an orphan once the job is no longer tracked.
func (l *Listener) track(jobID string) {
	l.trackedMu.Lock()
	l.tracked[jobID] = struct{}{}
	l.trackedMu.Unlock()
}

func (l *Listener) untrack(jobID string) {
	l.trackedMu.Lock()
	delete(l.tracked, jobID)
	l.trackedMu.Unlock()
}

// trackedJobIDs snapshots the currently in-flight job ids, handed to the reaper
// so their live containers are spared.
func (l *Listener) trackedJobIDs() []string {
	l.trackedMu.Lock()
	defer l.trackedMu.Unlock()
	ids := make([]string, 0, len(l.tracked))
	for id := range l.tracked {
		ids = append(ids, id)
	}
	return ids
}

// reap runs one orphan sweep (#105) if a Reaper is configured, passing the
// currently-tracked job ids so live containers are spared. A reaper error is
// logged and swallowed -- a failed sweep must never end the listen loop.
func (l *Listener) reap(ctx context.Context) {
	if l.cfg.Reaper == nil {
		return
	}
	if err := l.cfg.Reaper.Reap(ctx, l.trackedJobIDs()); err != nil {
		log.Printf("orphan reap failed (sweep skipped, listener continues): %v", err)
	}
}

// startReaper launches the periodic orphan sweep (#105) on its own goroutine,
// ticking every ReapInterval until the context is done. It is a no-op when no
// Reaper is configured. The returned stop function joins the goroutine, so a
// clean shutdown waits for any in-progress sweep.
func (l *Listener) startReaper(ctx context.Context) (stop func()) {
	if l.cfg.Reaper == nil {
		return func() {}
	}
	interval := l.cfg.ReapInterval
	if interval <= 0 {
		interval = defaultReapInterval
	}
	done := make(chan struct{})
	go func() {
		defer close(done)
		t := time.NewTicker(interval)
		defer t.Stop()
		for {
			select {
			case <-ctx.Done():
				return
			case <-t.C:
				l.reap(ctx)
			}
		}
	}()
	return func() { <-done }
}

// capacityFor is the spare-runner count to offer GitHub: the pool bound less
// the given local in-flight count (#102), clamped to [0, bound]. It is computed
// purely from local occupancy -- never the server's TotalAssignedJobs -- so the
// reported headroom is exactly what this host can still run. An over-subscribed
// count (more in-flight than the bound, which the semaphore prevents anyway)
// clamps to 0 rather than going negative.
func (l *Listener) capacityFor(inFlight int) int {
	spare := l.bound - inFlight
	if spare < 0 {
		return 0
	}
	return spare
}
