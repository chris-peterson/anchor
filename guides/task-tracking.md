# Task tracking

A skill that tracks its steps in the task list has to settle two things before
it creates anything: whether the session has the task tools at all, and whether
an orchestrator is already driving a list. Each skill's `## Task tracking`
section points here for both, then names its own tasks.

## Check the tool listing first

Claude Code offers `TaskCreate`, `TaskGet`, `TaskUpdate`, and `TaskList` only on
some models ([tools reference](https://code.claude.com/docs/en/tools-reference)).
Elsewhere the tools don't exist, and calling one prints
`No such tool available: TaskList` directly under the skill's
`Successfully loaded skill` line, so the skill reads as failing on arrival.

So read the session's tool listing before calling anything. The tools are
available when `TaskList` appears in either place:

- **The tools listed up front**, with a full schema. Call them directly.
- **The deferred-tools listing**, as a bare name. Load the schemas first with
  `ToolSearch("select:TaskCreate,TaskUpdate,TaskList")`. Calling a deferred tool
  before its schema is loaded fails with `InputValidationError`, which says
  nothing about whether the tool exists.

When `TaskList` is in neither, skip task tracking for the whole run and say
nothing about it. No list is the expected state in that session.

`TaskOutput` and `TaskStop` don't count. They drive background shell tasks and
stay available when the task list is off, so a match on the `Task` prefix
reports the list present when it isn't.

When the listing doesn't settle it, `ToolSearch("select:TaskList")` is the
check that can't error: for a tool the session lacks, it answers
`No matching deferred tools found`.

## Then look for an orchestrator

With the tools present, call `TaskList`. A task already `in_progress` means
another flow (a release, a merge cascade) owns the list: run silently inside it
and create no tasks of your own (UX-02). Otherwise create the skill's tasks as
its section names them.

## Naming the tasks

Name each task for the work it tracks, with no step number (UX-02a). A task
list covers only some of a skill's numbered steps, so numbers copied from the
headings show the user gaps for steps they never see.
