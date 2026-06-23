//go:build integration

// Live end-to-end integration test for the scale-set listener (ADR-0001
// Phase 4). This is the ONE thing the unit tests cannot cover: it drives the
// REAL github.com/actions/scaleset long-poll session against a REAL provisioned
// GitHub scale set, which needs live credentials and a scale set that this CI
// environment does not have. It is gated behind the `integration` build tag AND
// skips unless the live env knobs are set, so the default `go test ./...` never
// runs it. See README.md ("Live end-to-end gap").
//
// To run it manually against a real scale set:
//
//	GITHUB_CONFIG_URL=https://github.com/<org> \
//	GITHUB_TOKEN=<scale-set-admin-token> \
//	SCALE_SET_NAME=<name> \
//	go test -tags=integration -run TestLiveScaleSetSession ./...
package listener

import (
	"context"
	"os"
	"testing"
	"time"

	"github.com/actions/scaleset"
)

func TestLiveScaleSetSession(t *testing.T) {
	configURL := os.Getenv("GITHUB_CONFIG_URL")
	token := os.Getenv("GITHUB_TOKEN")
	scaleSetName := os.Getenv("SCALE_SET_NAME")
	if configURL == "" || token == "" || scaleSetName == "" {
		t.Skip("live scale set creds not set (GITHUB_CONFIG_URL / GITHUB_TOKEN / SCALE_SET_NAME); skipping live e2e")
	}

	ctx, cancel := context.WithTimeout(context.Background(), 60*time.Second)
	defer cancel()

	client, err := scaleset.NewClientWithPersonalAccessToken(
		scaleset.NewClientWithPersonalAccessTokenConfig{
			GitHubConfigURL:     configURL,
			PersonalAccessToken: token,
		},
	)
	if err != nil {
		t.Fatalf("create scale-set client: %v", err)
	}

	ss, err := client.GetRunnerScaleSet(ctx, 0, scaleSetName)
	if err != nil {
		t.Fatalf("get scale set %q: %v", scaleSetName, err)
	}
	session, err := client.MessageSessionClient(ctx, ss.ID, "")
	if err != nil {
		t.Fatalf("open scale-set session: %v", err)
	}

	// A recording provisioner so the live test observes demand without actually
	// pulling images / running containers; the real run path is provision-job.sh.
	prov := &recordingProvisioner{}
	l := New(session, prov, Config{Image: os.Getenv("RUNNER_IMAGE"), MaxRunners: 1})
	if err := l.Listen(ctx); err != nil && ctx.Err() == nil {
		t.Fatalf("live Listen failed: %v", err)
	}
	t.Logf("live session observed %d assigned-job provisions", len(prov.jobs))
}
