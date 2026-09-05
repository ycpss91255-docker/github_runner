// Command scaleset-listener is the production entrypoint that wires the
// official Runner Scale Set Client (github.com/actions/scaleset) into the
// provisioning glue in package listener (ADR-0001 Phase 4). It holds the
// outbound long-poll scale-set session and, for each ASSIGNED job, shells out
// to the per-job container provisioner (provision-job.sh -> Phase 3
// lib/runner-container.sh) so the job runs in a fresh, single-use, rootless
// container.
//
// This is the LIVE path: it needs a real GitHub config URL + a token with
// scale-set admin scope and a provisioned scale set, so it is NOT exercised by
// the unit tests (those drive package listener through the injectable Session
// seam). See README.md for the live end-to-end gap and the env knobs below.
package main

import (
	"context"
	"log"
	"os"
	"os/signal"
	"syscall"

	"github.com/actions/scaleset"

	"github.com/ycpss91255-docker/github_runner/listener"
)

// envOr returns the env var value, or a fallback when unset/empty.
func envOr(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}

// selectInstance loads the runner-type config (the Go loader is the
// authoritative parser, ADR-0003) and returns the Instance for the requested
// type. The "which type does this act on" rule itself lives in
// listener.SelectType, shared with the scaleset-admin lifecycle command, so the
// two commands can never disagree about which type a given config selects.
func selectInstance(path, typeName string, deps listener.InstanceDeps) (listener.Instance, error) {
	rt, err := listener.SelectType(path, typeName)
	if err != nil {
		return listener.Instance{}, err
	}
	return rt.Instance(deps), nil
}

func main() {
	// Ctrl-C / SIGTERM cancels the context so the listener's deferred
	// session teardown (Session.Close) runs on shutdown.
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	configURL := os.Getenv("GITHUB_CONFIG_URL") // e.g. https://github.com/<org>
	token := os.Getenv("GITHUB_TOKEN")          // scale-set admin scope
	owner := os.Getenv("SCALE_SET_OWNER")       // owner string for the session
	if configURL == "" || token == "" {
		log.Fatal("set GITHUB_CONFIG_URL and GITHUB_TOKEN")
	}

	// Host-inspection seams shared across runner types:
	//   - the GPU/device detector (#103/#113): one line per device from the
	//     enumeration command (default nvidia-smi -L), sizing a mode: auto type;
	//   - the reactive host probe (ADR-0005, #163): live per-resource headroom
	//     from host-probe.sh, driving reactive live-admission for the default types.
	// A missing tool falls back to the listener's conservative default bound.
	detector := listener.DeviceDetector(listener.CommandDeviceDetector{Name: envOr("DEVICE_DETECT_CMD", "nvidia-smi")})
	hostProbe := listener.HostProbe(listener.CommandHostProbe{Name: envOr("HOST_PROBE_CMD", "host-probe.sh")})
	deps := listener.InstanceDeps{Detector: detector, HostProbe: hostProbe}

	// Per-runner-type config (#110/#112): when RUNNER_TYPES_CONFIG is set, the Go
	// loader is the authoritative parser (ADR-0003). The selected runner type
	// (RUNNER_TYPE, or the sole type when there is exactly one) drives the scale
	// set, image and concurrency -- so adding/serving a second type is a config
	// entry, not a code change. Without it, the listener falls back to the
	// discrete SCALE_SET_NAME / RUNNER_IMAGE env knobs (reactive by default;
	// AUTO_SIZE_DEVICES opts into device sizing).
	//
	// SCALE_SET_NAME NAMES A SCALE SET; IT IS NOT WHAT WORKFLOWS TARGET. The
	// scale set is resolved by this name, but a workflow's runs-on is matched
	// against the scale set's LABELS, which are fixed when the scale set is
	// created (scaleset-admin create). They coincide only when the scale set was
	// created with its name as its single label -- which is what happens when a
	// runner type configures no labels of its own, and what makes the name look
	// like the routing target when it is not.
	var (
		scaleSetName string
		image        string
		reserve      int
		// Per-type provisioning fields carried across the widened shell-out
		// (#117/#119): devices for precise --device passthrough, the container
		// runtime shim, and the daemonless build tool. Empty in the discrete-env
		// path.
		devices   []string
		runtime   string
		buildTool string
	)
	if cfgPath := os.Getenv("RUNNER_TYPES_CONFIG"); cfgPath != "" {
		inst, err := selectInstance(cfgPath, os.Getenv("RUNNER_TYPE"), deps)
		if err != nil {
			log.Fatalf("runner-type config: %v", err)
		}
		scaleSetName = inst.ScaleSet
		image = inst.Config.Image
		devices = inst.Config.Devices
		runtime = inst.Config.Runtime
		buildTool = inst.Config.BuildTool
		reserve = inst.Config.Reserve
		// Carry exactly the seam this type resolved to: a device-sized (GPU) type
		// gets the detector and no probe; a reactive type gets the probe and no
		// detector.
		detector = inst.Config.DeviceDetector
		hostProbe = inst.Config.HostProbe
		log.Printf("runner type %q -> scale set %q (labels=%v)", inst.Name, inst.ScaleSet, inst.Labels)
	} else {
		// The scale set's IDENTIFIER, not the runs-on target (see above).
		scaleSetName = os.Getenv("SCALE_SET_NAME")
		image = envOr("RUNNER_IMAGE", "ghcr.io/actions/actions-runner:latest")
		// Reactive by default; AUTO_SIZE_DEVICES opts into device sizing instead.
		if os.Getenv("AUTO_SIZE_DEVICES") != "" {
			hostProbe = nil
		} else {
			detector = nil
		}
	}
	if scaleSetName == "" {
		log.Fatal("set SCALE_SET_NAME (or RUNNER_TYPES_CONFIG + RUNNER_TYPE)")
	}

	client, err := scaleset.NewClientWithPersonalAccessToken(
		scaleset.NewClientWithPersonalAccessTokenConfig{
			GitHubConfigURL:     configURL,
			PersonalAccessToken: token,
		},
	)
	if err != nil {
		log.Fatalf("create scale-set client: %v", err)
	}

	// Resolve the named scale set, then open the long-poll message session the
	// listener drives. The session is the official client's; we only supply the
	// per-job provisioning.
	//
	// ResolveScaleSet, not the raw client call: the client reports "no such
	// scale set" as (nil, nil), so dereferencing the result here used to panic
	// with a nil pointer when the scale set had not been created yet -- a stack
	// trace where the operator needed one sentence naming the create command.
	scaleSet, err := listener.ResolveScaleSet(ctx, client, scaleSetName)
	if err != nil {
		log.Fatal(err)
	}
	session, err := client.MessageSessionClient(ctx, scaleSet.ID, owner)
	if err != nil {
		log.Fatalf("open scale-set session: %v", err)
	}

	// Mint each job's single-use JIT config via the Go client (ADR-0001:
	// minting lives on the Go side of the boundary).
	minter := &listener.ClientJITMinter{Client: client, ScaleSetID: scaleSet.ID}
	prov := &listener.ContainerProvisioner{Script: envOr("PROVISION_SCRIPT", "provision-job.sh")}
	reaper := &listener.ScriptReaper{Script: envOr("REAP_SCRIPT", "reap.sh")}
	// Structured per-job logging (#131): one record per finished job (id, image,
	// exit, duration) plus periodic capacity/in-flight snapshots, emitted via slog
	// to stderr, which journald captures when this runs as a systemd unit.
	l := listener.New(session, minter, prov, listener.Config{
		Image:          image,
		DeviceDetector: detector,
		HostProbe:      hostProbe,
		Reserve:        reserve,
		Reaper:         reaper,
		Devices:        devices,
		Runtime:        runtime,
		BuildTool:      buildTool,
		JobLogger:      listener.NewJournalJobLogger(),
	})

	log.Printf("listener up: scale set %q (id=%d), image=%s", scaleSetName, scaleSet.ID, image)
	if err := l.Listen(ctx); err != nil {
		log.Fatalf("listener exited with error: %v", err)
	}
	log.Print("listener exited cleanly")
}
