// Command scaleset-admin is the runner scale set lifecycle tool: it CREATES
// and DELETES the GitHub scale set a runner type binds to, using the same
// official client (github.com/actions/scaleset) the listener runs on.
//
// It exists because the repo could connect to a scale set but had nothing that
// made one, so an operator following the deploy runbook reached "fill in the
// scale set name" with no way to obtain a scale set at all.
//
// IT IS DRIVEN BY THE RUNNER-TYPE CONFIG, NOT BY AD-HOC FLAGS. The name comes
// from the type's `scale_set` and the routing labels from its `labels`, so
// deploy/runner-types.yaml stays the single source of truth for routing and the
// name/labels mismatch that strands every job in `queued` cannot be introduced
// here.
//
// WHAT WORKFLOWS TARGET. A workflow's `runs-on` is matched against the scale
// set's LABELS. The scale set NAME is only an identifier. When a type
// configures no labels, the labels are set to exactly the scale set name (so
// `runs-on: <name>` works) -- explicitly, never by leaving the field empty for
// the client to fill in. Both commands print the literal `runs-on:` line to
// paste into a workflow.
//
//	scaleset-admin create [--config <path>] [--type <name>] [--group <name>] [--dry-run]
//	scaleset-admin delete [--config <path>] [--type <name>] (--yes | --dry-run)
//
// Credentials come from the environment (GITHUB_CONFIG_URL, GITHUB_TOKEN),
// never from a flag: a token in a flag is a token in the host process table.
package main

import (
	"context"
	"flag"
	"fmt"
	"os"
	"strings"

	"github.com/actions/scaleset"

	"github.com/ycpss91255-docker/github_runner/listener"
)

// usage is printed for -h and for any usage error, so the two agree.
const usage = `usage:
  scaleset-admin create [--config <path>] [--type <name>] [--group <name>] [--dry-run]
  scaleset-admin delete [--config <path>] [--type <name>] (--yes | --dry-run)
  scaleset-admin show   [--config <path>] [--type <name>]

Create or delete the GitHub runner scale set a runner type binds to. The scale
set NAME and its routing LABELS both come from the runner-type config; there is
deliberately no way to pass either as a flag.

The show verb reports what the config says about a runner type, as key=value
lines (name, scale_set, labels, image, runs_on), and makes NO network call. It
is how the deploy tooling learns a type's scale set and routing labels without
re-implementing a YAML parser in shell -- the Go loader stays the only parser.

  --config <path>   runner-type config (default: $RUNNER_TYPES_CONFIG)
  --type <name>     which runner type to act on (default: $RUNNER_TYPE; may be
                    omitted when the config holds exactly one type)
  --group <name>    runner group to create in (default: Default)
  --dry-run         print the plan; change nothing
  --yes             required by delete: it is destructive and not reversible
                    from here (the scale set has to be created again)

Environment (never flags -- a token in a flag is a token in the process table):
  GITHUB_CONFIG_URL   https://github.com/<org>
  GITHUB_TOKEN        a token with scale-set admin scope
`

// options are the parsed flags shared by both subcommands.
type options struct {
	config  string
	typ     string
	group   string
	dryRun  bool
	yes     bool
	verb    string
	flagSet *flag.FlagSet
}

// parseArgs reads the subcommand plus its flags. The subcommand comes first so
// the surface reads as a verb on a noun, matching the shell scripts.
func parseArgs(args []string) (options, error) {
	if len(args) == 0 {
		return options{}, fmt.Errorf("a subcommand is required (create, delete or show)")
	}
	opts := options{verb: args[0]}
	switch opts.verb {
	case "create", "delete", "show":
	case "-h", "--help", "help":
		fmt.Print(usage)
		os.Exit(0)
	default:
		return options{}, fmt.Errorf("unknown subcommand %q (want create, delete or show)", opts.verb)
	}

	fs := flag.NewFlagSet("scaleset-admin "+opts.verb, flag.ContinueOnError)
	fs.SetOutput(os.Stderr)
	fs.Usage = func() { fmt.Fprint(os.Stderr, usage) }
	fs.StringVar(&opts.config, "config", os.Getenv("RUNNER_TYPES_CONFIG"), "runner-type config path")
	fs.StringVar(&opts.typ, "type", os.Getenv("RUNNER_TYPE"), "runner type to act on")
	fs.StringVar(&opts.group, "group", "", "runner group to create in")
	fs.BoolVar(&opts.dryRun, "dry-run", false, "print the plan; change nothing")
	fs.BoolVar(&opts.yes, "yes", false, "confirm a destructive action")
	if err := fs.Parse(args[1:]); err != nil {
		return options{}, err
	}
	opts.flagSet = fs
	if opts.config == "" {
		return options{}, fmt.Errorf("--config (or RUNNER_TYPES_CONFIG) is required")
	}
	if opts.verb == "delete" && !opts.yes && !opts.dryRun {
		return options{}, fmt.Errorf("delete is destructive: pass --yes to confirm (or --dry-run to preview)")
	}
	return opts, nil
}

// newAdmin builds the real scale-set client from the environment. Both
// credentials are environment-only on purpose.
func newAdmin() (listener.ScaleSetAdmin, error) {
	configURL := os.Getenv("GITHUB_CONFIG_URL")
	token := os.Getenv("GITHUB_TOKEN")
	if configURL == "" || token == "" {
		return nil, fmt.Errorf("set GITHUB_CONFIG_URL and GITHUB_TOKEN")
	}
	client, err := scaleset.NewClientWithPersonalAccessToken(
		scaleset.NewClientWithPersonalAccessTokenConfig{
			GitHubConfigURL:     configURL,
			PersonalAccessToken: token,
		},
	)
	if err != nil {
		return nil, fmt.Errorf("create scale-set client: %w", err)
	}
	return client, nil
}

// runCreate ensures the type's scale set exists and reports which of the two
// idempotent outcomes happened, then prints the runs-on line to paste.
func runCreate(ctx context.Context, admin listener.ScaleSetAdmin, rt listener.RunnerType, group string) error {
	res, err := listener.EnsureScaleSet(ctx, admin, rt, group)
	if err != nil {
		return err
	}
	if res.Created {
		fmt.Printf("created scale set %q (id=%d) for runner type %q\n", res.Name, res.ID, rt.Name)
	} else {
		fmt.Printf("scale set %q (id=%d) already exists for runner type %q; nothing changed\n", res.Name, res.ID, rt.Name)
		if !res.LabelsMatch {
			fmt.Fprintf(os.Stderr, "WARNING: its live labels [%s] do NOT match the configured [%s].\n",
				strings.Join(res.LiveLabels, ", "), strings.Join(listener.RoutingLabels(rt), ", "))
			fmt.Fprintf(os.Stderr, "         Workflows route on the LIVE labels. Either fix the config to match, or\n")
			fmt.Fprintf(os.Stderr, "         delete and recreate the scale set.\n")
		}
	}
	printRunsOn(res.Labels)
	return nil
}

// printRunsOn is the single most useful thing this command prints: the exact
// line a workflow needs. Targeting the scale set NAME when the labels are
// something else is the mistake that leaves jobs queued forever, so the literal
// answer is printed rather than described.
func printRunsOn(labels []string) {
	fmt.Println()
	fmt.Println("Workflows target this runner type by its LABELS (the name is only an identifier).")
	fmt.Printf("Paste into your workflow job:\n\n    %s\n", listener.RunsOn(labels))
}

// runDelete removes the type's scale set, or reports that there was nothing to
// remove.
func runDelete(ctx context.Context, admin listener.ScaleSetAdmin, rt listener.RunnerType) error {
	res, err := listener.DeleteScaleSet(ctx, admin, rt)
	if err != nil {
		return err
	}
	if res.Deleted {
		fmt.Printf("deleted scale set %q (id=%d)\n", res.Name, res.ID)
	} else {
		fmt.Printf("no scale set named %q exists; nothing to delete\n", res.Name)
	}
	return nil
}

func main() {
	opts, err := parseArgs(os.Args[1:])
	if err != nil {
		fmt.Fprintf(os.Stderr, "scaleset-admin: %v\n\n%s", err, usage)
		os.Exit(2)
	}

	rt, err := listener.SelectType(opts.config, opts.typ)
	if err != nil {
		fmt.Fprintf(os.Stderr, "scaleset-admin: %v\n", err)
		os.Exit(1)
	}
	labels := listener.RoutingLabels(rt)

	// `show` is a pure read of the config: no plan, no confirmation, no client,
	// no network. It exists to be consumed by other tooling (the deploy
	// command), so it prints the report and nothing else.
	if opts.verb == "show" {
		for _, line := range listener.DescribeType(rt) {
			fmt.Println(line)
		}
		return
	}

	// The outward action is announced before it is taken, in both modes: a
	// dry run stops here, a real run has already said exactly what it is about
	// to create on GitHub.
	switch opts.verb {
	case "create":
		group := opts.group
		if group == "" {
			group = listener.DefaultRunnerGroup
		}
		fmt.Printf("Plan (GitHub side):\n")
		fmt.Printf("  Runner type:    %s\n", rt.Name)
		fmt.Printf("  Scale set:      %s   (identifier)\n", rt.ScaleSet)
		fmt.Printf("  Routing labels: %s   (what runs-on matches)\n", strings.Join(labels, ", "))
		fmt.Printf("  Runner group:   %s\n", group)
		fmt.Println("  Action:         create it if it does not already exist")
	case "delete":
		fmt.Printf("Plan (GitHub side):\n")
		fmt.Printf("  Runner type:    %s\n", rt.Name)
		fmt.Printf("  Scale set:      %s\n", rt.ScaleSet)
		fmt.Println("  Action:         DELETE it from GitHub")
		fmt.Println("  Consequence:    workflows targeting its labels stop being served")
	}
	fmt.Println()

	if opts.dryRun {
		fmt.Println("Dry run; nothing was changed.")
		if opts.verb == "create" {
			printRunsOn(labels)
		}
		return
	}

	admin, err := newAdmin()
	if err != nil {
		fmt.Fprintf(os.Stderr, "scaleset-admin: %v\n", err)
		os.Exit(1)
	}

	ctx := context.Background()
	switch opts.verb {
	case "create":
		err = runCreate(ctx, admin, rt, opts.group)
	case "delete":
		err = runDelete(ctx, admin, rt)
	}
	if err != nil {
		fmt.Fprintf(os.Stderr, "scaleset-admin: %v\n", err)
		os.Exit(1)
	}
}
