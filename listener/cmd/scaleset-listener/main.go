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

func main() {
	// Ctrl-C / SIGTERM cancels the context so the listener's deferred
	// session teardown (Session.Close) runs on shutdown.
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	configURL := os.Getenv("GITHUB_CONFIG_URL") // e.g. https://github.com/<org>
	token := os.Getenv("GITHUB_TOKEN")          // scale-set admin scope
	scaleSetName := os.Getenv("SCALE_SET_NAME") // the workflows' runs-on target
	image := envOr("RUNNER_IMAGE", "ghcr.io/actions/actions-runner:latest")
	owner := os.Getenv("SCALE_SET_OWNER") // owner string for the session
	if configURL == "" || token == "" || scaleSetName == "" {
		log.Fatal("set GITHUB_CONFIG_URL, GITHUB_TOKEN, and SCALE_SET_NAME")
	}
	maxRunners := 0
	if v := os.Getenv("MAX_RUNNERS"); v != "" {
		n, err := strconv.Atoi(v)
		if err != nil {
			log.Fatalf("MAX_RUNNERS must be an integer: %v", err)
		}
		maxRunners = n
	}
	// Optional auto-sizing (#103): when AUTO_SIZE_DEVICES is set and MAX_RUNNERS
	// is not, the worker-pool bound is the detected device count (one line per
	// device from the enumeration command, default nvidia-smi -L). A detection
	// failure falls back to the listener's default bound, so a host without the
	// tool still runs.
	var detector listener.DeviceDetector
	if os.Getenv("AUTO_SIZE_DEVICES") != "" {
		detector = listener.CommandDeviceDetector{Name: envOr("DEVICE_DETECT_CMD", "nvidia-smi")}
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
	l := listener.New(session, minter, prov, listener.Config{
		Image:          image,
		MaxRunners:     maxRunners,
		DeviceDetector: detector,
	})

	log.Printf("listener up: scale set %q (id=%d), image=%s", scaleSetName, scaleSet.ID, image)
	if err := l.Listen(ctx); err != nil {
		log.Fatalf("listener exited with error: %v", err)
	}
	log.Print("listener exited cleanly")
}
