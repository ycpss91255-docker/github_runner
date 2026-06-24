package listener

import (
	"context"
	"fmt"

	"github.com/actions/scaleset"
)

// ClientJITMinter is the production JITConfigMinter: it mints each runner's
// single-use JIT config via the scale-set Go client's GenerateJitRunnerConfig
// (a method on *scaleset.Client, not on the message session). ADR-0001/ADR-0003
// place minting on the Go side of the boundary -- the bash side never mints --
// so this thin adapter is the one place the client's mint call is named, and the
// listener depends only on the JITConfigMinter interface it satisfies.
type ClientJITMinter struct {
	// Client is the scale-set client that performs the actual mint.
	Client *scaleset.Client
	// ScaleSetID is the resolved scale set the runner registers into.
	ScaleSetID int
}

// Mint generates the encoded JIT config for a runner named name. The labels are
// part of the JobAssigned message but the v0.4.0 GenerateJitRunnerConfig setting
// only carries the runner name + work folder (the scale set already pins the
// labels for its runners), so they are accepted for the interface but the scale
// set's own configuration governs labels.
func (m *ClientJITMinter) Mint(ctx context.Context, name string, _ []string) (string, error) {
	cfg, err := m.Client.GenerateJitRunnerConfig(
		ctx,
		&scaleset.RunnerScaleSetJitRunnerSetting{
			Name:       name,
			WorkFolder: "_work",
		},
		m.ScaleSetID,
	)
	if err != nil {
		return "", fmt.Errorf("mint JIT config for %s: %w", name, err)
	}
	return cfg.EncodedJITConfig, nil
}
