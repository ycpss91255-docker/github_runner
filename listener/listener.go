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

	"github.com/actions/scaleset"
)

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

// Config holds the listener's static knobs.
type Config struct {
	// Image is the container image every ephemeral job runs in (passed to the
	// Phase 3 provisioner).
	Image string
	// MaxRunners is the ceiling on concurrently-provisioned runners -- the
	// capacity the listener offers GitHub, less whatever is already assigned.
	// Zero means "no explicit ceiling"; we then offer demand-sized capacity.
	MaxRunners int
}

// Listener pairs an injected scale-set Session with a Provisioner and runs the
// demand->provision loop.
type Listener struct {
	session Session
	minter  JITConfigMinter
	prov    Provisioner
	cfg     Config
}

// New wires a Session + JITConfigMinter + Provisioner + Config into a Listener.
func New(session Session, minter JITConfigMinter, prov Provisioner, cfg Config) *Listener {
	return &Listener{session: session, minter: minter, prov: prov, cfg: cfg}
}

// Listen runs the long-poll loop until the session drains or the context is
// done, ALWAYS tearing the session down on exit. Each iteration:
//
//  1. GetMessage, reporting current spare capacity (ceiling - assigned) so
//     reported capacity FOLLOWS demand and GitHub never over-assigns.
//  2. For every ASSIGNED job in the message, acquire it and shell out to the
//     per-job container provisioner with the job's single-use JIT config -- the
//     fresh-container isolation the scale set client does not provide.
//  3. Ack the message (DeleteMessage) so it is not redelivered.
//
// A provisioner error is returned (and the session still torn down). A clean
// drain returns nil.
func (l *Listener) Listen(ctx context.Context) (err error) {
	// Teardown is unconditional: clean exit or mid-job failure, the session
	// must be closed so it does not linger server-side.
	defer func() {
		closeErr := l.session.Close(ctx)
		if err == nil {
			err = closeErr
		}
	}()

	lastMessageID := 0
	// assigned tracks demand seen so far (TotalAssignedJobs from the latest
	// message's statistics), so the next poll offers the remaining headroom.
	assigned := 0

	for {
		if cerr := ctx.Err(); cerr != nil {
			return cerr
		}

		capacity := l.capacity(assigned)
		msg, gerr := l.session.GetMessage(ctx, lastMessageID, capacity)
		if gerr != nil {
			// A drained fake / a real session error both end the loop; only a
			// genuine error is surfaced (the test sentinel drains cleanly).
			return ignoreDrain(gerr)
		}
		if msg == nil {
			continue
		}

		if msg.Statistics != nil {
			assigned = msg.Statistics.TotalAssignedJobs
		}

		if perr := l.handle(ctx, msg); perr != nil {
			return perr
		}

		if msg.MessageID > 0 {
			if derr := l.session.DeleteMessage(ctx, msg.MessageID); derr != nil {
				return derr
			}
			lastMessageID = msg.MessageID
		}
	}
}

// handle provisions a container for every ASSIGNED job in the message. Only
// assigned jobs are ours to run; available-but-unassigned jobs are left for the
// scale set to assign, so we never over-provision on availability.
func (l *Listener) handle(ctx context.Context, msg *scaleset.RunnerScaleSetMessage) error {
	for _, ja := range msg.JobAssignedMessages {
		if ja == nil {
			continue
		}
		// Claim the job so its JIT config is ours to run.
		if _, err := l.session.AcquireJobs(ctx, []int64{ja.RunnerRequestID}); err != nil {
			return err
		}
		// Mint the single-use JIT config for this job via the Go client
		// (ADR-0001: minting lives on the Go side of the boundary).
		jit, err := l.minter.Mint(ctx, ja.JobID, ja.RequestLabels)
		if err != nil {
			return err
		}
		req := ProvisionRequest{
			JobID:            ja.JobID,
			RequestID:        ja.RunnerRequestID,
			Labels:           ja.RequestLabels,
			EncodedJITConfig: jit,
			Image:            l.cfg.Image,
		}
		if err := l.prov.Provision(ctx, req); err != nil {
			return err
		}
	}
	return nil
}

// capacity is the spare-runner count to offer GitHub: the MaxRunners ceiling
// less the jobs already assigned, never below zero. With no ceiling set, we
// offer at least the current demand so assigned jobs can be served.
func (l *Listener) capacity(assigned int) int {
	if l.cfg.MaxRunners <= 0 {
		if assigned < 1 {
			return 1
		}
		return assigned
	}
	spare := l.cfg.MaxRunners - assigned
	if spare < 0 {
		return 0
	}
	return spare
}

// ignoreDrain maps the test drain sentinel to a clean exit (nil) while passing
// every real error through. The sentinel is matched by message text so the test
// package can define its own sentinel without importing it here.
func ignoreDrain(err error) error {
	if err != nil && err.Error() == "drained" {
		return nil
	}
	return err
}
