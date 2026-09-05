package listener

import (
	"context"
	"fmt"
	"strings"

	"github.com/actions/scaleset"
)

// DefaultRunnerGroup is the runner group a scale set is created in when the
// operator names none. It is GitHub's standard group, the one every
// self-hosted runner lands in unless someone has deliberately organised them
// otherwise.
const DefaultRunnerGroup = "Default"

// ScaleSetAdmin is the subset of the official scale-set client
// (*scaleset.Client) the lifecycle commands drive: look a scale set up, look a
// runner group up, create, delete. Defining it as an interface here -- rather
// than taking the concrete client -- is the same seam Session and Provisioner
// use, and it is what lets the create/delete logic be unit-tested with no
// credentials and no live GitHub.
type ScaleSetAdmin interface {
	// GetRunnerScaleSet finds a scale set by name within a runner group (0
	// searches across groups). IMPORTANT: the client reports "no such scale
	// set" as (nil, nil), NOT as an error -- see ResolveScaleSet.
	GetRunnerScaleSet(ctx context.Context, runnerGroupID int, name string) (*scaleset.RunnerScaleSet, error)
	// GetRunnerGroupByName resolves a runner group name to its id.
	GetRunnerGroupByName(ctx context.Context, name string) (*scaleset.RunnerGroup, error)
	// CreateRunnerScaleSet creates a scale set. Names are unique within a
	// runner group.
	CreateRunnerScaleSet(ctx context.Context, set *scaleset.RunnerScaleSet) (*scaleset.RunnerScaleSet, error)
	// DeleteRunnerScaleSet deletes a scale set by id.
	DeleteRunnerScaleSet(ctx context.Context, id int) error
}

// The official client must be drop-in for the seam, so production hands a
// *scaleset.Client straight into these functions.
var _ ScaleSetAdmin = (*scaleset.Client)(nil)

// ScaleSetResult is the outcome of ensuring a runner type's scale set exists.
// It distinguishes "I made it" from "it was already there" so an idempotent
// re-run reports the truth rather than pretending it did work.
type ScaleSetResult struct {
	// Name is the scale set's name -- an identifier only. It is NOT what a
	// workflow's runs-on targets unless it also appears in Labels.
	Name string
	// ID is the server-assigned scale set id.
	ID int
	// Labels are the EFFECTIVE routing labels: what a workflow's runs-on must
	// match. On a create these are the labels that were written; on an
	// already-exists these are the labels the live scale set actually carries.
	Labels []string
	// Created is true only when this call created the scale set. False means
	// it was already there and nothing was mutated.
	Created bool
	// LabelsMatch reports whether the live scale set's labels equal the ones
	// the configuration asks for. Only meaningful when Created is false; a
	// false value means the config and the routing target disagree.
	LabelsMatch bool
	// LiveLabels are the labels the existing scale set carries when they
	// differ from the configured ones, so a mismatch can be reported concretely
	// instead of as "something is different".
	LiveLabels []string
}

// DeleteResult is the outcome of deleting a runner type's scale set. Deleted
// is false when there was nothing to delete -- a no-op that succeeded, not a
// failure, so a teardown re-run does not fail on its own success.
type DeleteResult struct {
	Name    string
	ID      int
	Deleted bool
}

// RoutingLabels are the labels a runner type's scale set routes on.
//
// THIS IS THE ROUTING KEY. A workflow's runs-on is matched against the scale
// set's LABELS; the scale set's name is only an identifier. Two modes:
//
//   - labels configured -> used verbatim, and the name is never added to them;
//   - no labels configured -> exactly the scale set name, so name and routing
//     key coincide and a workflow simply writes `runs-on: <name>`.
//
// The second mode is spelled out here rather than left to the client, which
// fills labels from the name only when the field arrives empty. Relying on
// that implicit fallback is what makes the routing key unwritten-down
// everywhere, which is exactly how a job ends up sitting in queued with no
// indication why. Whatever the routing key is, it is stated.
func RoutingLabels(rt RunnerType) []string {
	if len(rt.Labels) > 0 {
		return rt.Labels
	}
	return []string{rt.ScaleSet}
}

// RunsOn renders the literal workflow line that targets these labels, ready to
// paste: a single label as `runs-on: <label>`, several as the list form. Given
// that targeting the name instead of the labels is the mistake this whole
// surface exists to prevent, printing the exact line is more useful than any
// amount of explanation.
func RunsOn(labels []string) string {
	switch len(labels) {
	case 0:
		return ""
	case 1:
		return "runs-on: " + labels[0]
	default:
		return "runs-on: [" + strings.Join(labels, ", ") + "]"
	}
}

// labelNames flattens the client's label structs to plain names.
func labelNames(labels []scaleset.Label) []string {
	names := make([]string, 0, len(labels))
	for _, l := range labels {
		names = append(names, l.Name)
	}
	return names
}

// sameLabels reports whether two label sets are identical, order included. The
// order is part of it deliberately: the configuration is the source of truth,
// and a live scale set that lists the same labels in another order is still a
// scale set nobody's config describes.
func sameLabels(a, b []string) bool {
	if len(a) != len(b) {
		return false
	}
	for i := range a {
		if a[i] != b[i] {
			return false
		}
	}
	return true
}

// EnsureScaleSet creates the GitHub scale set a runner type binds to, and is
// idempotent: if the scale set already exists it is left exactly as it is and
// reported as such, so running the deploy on a second machine performs no
// GitHub-side work at all.
//
// The name comes from the type's scale_set and the routing labels from
// RoutingLabels, so deploy/runner-types.yaml is the single source of truth for
// routing and the name/labels mismatch that strands jobs in queued cannot be
// introduced by a flag.
//
// groupName is the runner group to create in; empty means DefaultRunnerGroup.
// An unresolvable group is an error with nothing created -- creating in group 0
// instead would put the scale set somewhere the operator did not ask for.
func EnsureScaleSet(ctx context.Context, admin ScaleSetAdmin, rt RunnerType, groupName string) (ScaleSetResult, error) {
	labels := RoutingLabels(rt)

	// Look first. A lookup FAILURE is a failure: proceeding on "I could not
	// tell whether it exists" is how a duplicate gets created.
	existing, err := admin.GetRunnerScaleSet(ctx, 0, rt.ScaleSet)
	if err != nil {
		return ScaleSetResult{}, fmt.Errorf("look up scale set %q: %w", rt.ScaleSet, err)
	}
	if existing != nil {
		live := labelNames(existing.Labels)
		res := ScaleSetResult{
			Name:        existing.Name,
			ID:          existing.ID,
			Labels:      live,
			Created:     false,
			LabelsMatch: sameLabels(live, labels),
		}
		if !res.LabelsMatch {
			res.LiveLabels = live
		}
		return res, nil
	}

	if groupName == "" {
		groupName = DefaultRunnerGroup
	}
	group, err := admin.GetRunnerGroupByName(ctx, groupName)
	if err != nil {
		return ScaleSetResult{}, fmt.Errorf("resolve runner group %q: %w", groupName, err)
	}

	// Labels are written EXPLICITLY, never left empty for the client to fill
	// from the name (see RoutingLabels).
	want := make([]scaleset.Label, 0, len(labels))
	for _, name := range labels {
		want = append(want, scaleset.Label{Name: name, Type: "System"})
	}
	created, err := admin.CreateRunnerScaleSet(ctx, &scaleset.RunnerScaleSet{
		Name:            rt.ScaleSet,
		RunnerGroupID:   group.ID,
		RunnerGroupName: group.Name,
		Labels:          want,
	})
	if err != nil {
		return ScaleSetResult{}, fmt.Errorf("create scale set %q: %w", rt.ScaleSet, err)
	}
	return ScaleSetResult{
		Name:        created.Name,
		ID:          created.ID,
		Labels:      labelNames(created.Labels),
		Created:     true,
		LabelsMatch: true,
	}, nil
}

// DeleteScaleSet removes the GitHub scale set a runner type binds to. Deleting
// is always an explicit act -- nothing else in this repo calls it -- and an
// absent scale set is a successful no-op so a teardown can be re-run.
func DeleteScaleSet(ctx context.Context, admin ScaleSetAdmin, rt RunnerType) (DeleteResult, error) {
	existing, err := admin.GetRunnerScaleSet(ctx, 0, rt.ScaleSet)
	if err != nil {
		return DeleteResult{}, fmt.Errorf("look up scale set %q: %w", rt.ScaleSet, err)
	}
	if existing == nil {
		return DeleteResult{Name: rt.ScaleSet}, nil
	}
	if err := admin.DeleteRunnerScaleSet(ctx, existing.ID); err != nil {
		return DeleteResult{}, fmt.Errorf("delete scale set %q (id=%d): %w", existing.Name, existing.ID, err)
	}
	return DeleteResult{Name: existing.Name, ID: existing.ID, Deleted: true}, nil
}

// ResolveScaleSet fetches a scale set by name, turning the client's "(nil, nil)
// means absent" contract into an error that says what to do about it.
//
// The distinction matters: the production entrypoint used to dereference that
// nil, so a listener pointed at a scale set nobody had created yet died with a
// nil-pointer panic -- a stack trace where the operator needed one sentence.
func ResolveScaleSet(ctx context.Context, admin ScaleSetAdmin, name string) (*scaleset.RunnerScaleSet, error) {
	set, err := admin.GetRunnerScaleSet(ctx, 0, name)
	if err != nil {
		return nil, fmt.Errorf("get scale set %q: %w", name, err)
	}
	if set == nil {
		return nil, fmt.Errorf("no scale set named %q exists -- create it first with `scaleset-admin create`", name)
	}
	return set, nil
}

// SelectType loads the runner-type config and returns the one entry the caller
// acts on. A named type is looked up; an unnamed one resolves only when the
// config holds exactly one type, because a listener process (and an admin
// command) serves exactly one homogeneous scale set (ADR-0001).
//
// It is shared by the listener entrypoint and the admin command so the two can
// never disagree about which type a given config selects.
func SelectType(path, typeName string) (RunnerType, error) {
	types, err := LoadConfig(path)
	if err != nil {
		return RunnerType{}, err
	}
	if typeName == "" {
		if len(types) != 1 {
			return RunnerType{}, fmt.Errorf("name a runner type: %s configures %d of them", path, len(types))
		}
		return types[0], nil
	}
	for _, rt := range types {
		if rt.Name == typeName {
			return rt, nil
		}
	}
	return RunnerType{}, fmt.Errorf("no runner type named %q in %s", typeName, path)
}
