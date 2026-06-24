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
	"fmt"
	"log"
	"os"
	"os/signal"
	"strconv"
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
// type. When typeName is empty it must resolve unambiguously -- exactly one type
// in the file -- otherwise the operator must name which type this listener
// serves (one listener process serves one homogeneous scale set, ADR-0001).
func selectInstance(path, typeName string, det listener.DeviceDetector) (listener.Instance, error) {
	types, err := listener.LoadConfig(path)
	if err != nil {
		return listener.Instance{}, err
	}
	if typeName == "" {
		if len(types) != 1 {
			return listener.Instance{}, fmt.Errorf("RUNNER_TYPE must name one of %d configured runner types", len(types))
		}
		return types[0].Instance(det), nil
	}
	for _, rt := range types {
		if rt.Name == typeName {
			return rt.Instance(det), nil
		}
	}
	return listener.Instance{}, fmt.Errorf("no runner type named %q in %s", typeName, path)
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

	// The GPU/auto-size detector (#103/#113): one line per device from the
	// enumeration command (default nvidia-smi -L). A detection failure falls
	// back to the listener's default bound, so a host without the tool still
	// runs. Always available so an auto-concurrency runner type can size to it.
	detector := listener.DeviceDetector(listener.CommandDeviceDetector{Name: envOr("DEVICE_DETECT_CMD", "nvidia-smi")})

	// Per-runner-type config (#110/#112): when RUNNER_TYPES_CONFIG is set, the Go
	// loader is the authoritative parser (ADR-0003). The selected runner type
	// (RUNNER_TYPE, or the sole type when there is exactly one) drives the scale
	// set, image and concurrency -- so adding/serving a second type is a config
	// entry, not a code change. Without it, the listener falls back to the
	// discrete SCALE_SET_NAME / RUNNER_IMAGE / MAX_RUNNERS env knobs.
	var (
		scaleSetName string
		image        string
		maxRunners   int
		// Per-type provisioning fields carried across the widened shell-out
		// (#117/#119): devices for precise --device passthrough, the hardening
		// posture, and the daemonless build tool. Empty in the discrete-env path.
		devices          []string
		hardeningProfile string
		buildTool        string
	)
	if cfgPath := os.Getenv("RUNNER_TYPES_CONFIG"); cfgPath != "" {
		inst, err := selectInstance(cfgPath, os.Getenv("RUNNER_TYPE"), detector)
		if err != nil {
			log.Fatalf("runner-type config: %v", err)
		}
		scaleSetName = inst.ScaleSet
		image = inst.Config.Image
		maxRunners = inst.Config.MaxRunners
		devices = inst.Config.Devices
		hardeningProfile = inst.Config.HardeningProfile
		buildTool = inst.Config.BuildTool
		if inst.Config.DeviceDetector == nil {
			// A fixed-concurrency type pins MaxRunners and must not be auto-sized.
			detector = nil
		}
		log.Printf("runner type %q -> scale set %q (labels=%v)", inst.Name, inst.ScaleSet, inst.Labels)
	} else {
		scaleSetName = os.Getenv("SCALE_SET_NAME") // the workflows' runs-on target
		image = envOr("RUNNER_IMAGE", "ghcr.io/actions/actions-runner:latest")
		if v := os.Getenv("MAX_RUNNERS"); v != "" {
			n, err := strconv.Atoi(v)
			if err != nil {
				log.Fatalf("MAX_RUNNERS must be an integer: %v", err)
			}
			maxRunners = n
		}
		// In the discrete-env path, auto-size only when explicitly asked.
		if os.Getenv("AUTO_SIZE_DEVICES") == "" {
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
	scaleSet, err := client.GetRunnerScaleSet(ctx, 0, scaleSetName)
	if err != nil {
		log.Fatalf("get scale set %q: %v", scaleSetName, err)
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
	l := listener.New(session, minter, prov, listener.Config{
		Image:            image,
		MaxRunners:       maxRunners,
		DeviceDetector:   detector,
		Reaper:           reaper,
		Devices:          devices,
		HardeningProfile: hardeningProfile,
		BuildTool:        buildTool,
	})

	log.Printf("listener up: scale set %q (id=%d), image=%s", scaleSetName, scaleSet.ID, image)
	if err := l.Listen(ctx); err != nil {
		log.Fatalf("listener exited with error: %v", err)
	}
	log.Print("listener exited cleanly")
}
