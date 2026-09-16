# Testing Guide

## 1. Purpose

This project has two testing layers:

- Deterministic suite (`test/runtests.jl`): protocol, state, queue, dispatch,
  timeout, callback, server admission, and local multi-process executor restart
  and shutdown regressions. No configured LAN nodes are contacted.
- Manual integration tests: explicitly selected conductor/server LAN endpoints.

The deterministic suite starts every test file in an isolated Julia process.
This prevents conductor registries, log writers, environment variables, and
test helper globals from leaking into the next test.

## 2. File layout

- `examples/01_basic_server_client.jl`: direct client -> server flow.
- `examples/02_conductor_list.jl`: query conductor `LIST` and print available nodes.
- `examples/03_submit_dispatch_retry.jl`: submit task to conductor and wait callback.
- `test/runtests.jl`: isolated deterministic test entrypoint (35 files).
- `test/unit_client_protocol.jl`: checksum and parse tests for client protocol.
- `test/unit_conductor_queue.jl`: conductor queue, LIFO, retry, default callback port tests.
- `test/integration_single_pc.jl`: manual one-PC integration smoke test.
- `test/integration_conductor_node_exclusivity.jl`: four-task lan100
  exclusivity and task-terminal regression.

## 3. Run the deterministic suite

```bash
julia --startup-file=no --project=. --threads=4 test/runtests.jl
```

The command exits nonzero if a child test exits nonzero or writes to stderr.
Conductor logs used by the suite are placed in a temporary directory and
removed at the end, so `logs/conductor_events.csv` is not modified.

The additional executor/restart tests cover:

- `regression_package_reload_boundary.jl`: cache clear versus an already-loaded
  package, using the same package UUID and both overwrite and directory-switch cases.
- `unit_executor_loading.jl`, `unit_server_runtime_state.jl`,
  `unit_executor_protocol.jl`: loading behavior, identities, exclusive state
  transitions, bounded frames, and stale-response rejection.
- `integration_executor_loop.jl`, `integration_executor_lifecycle.jl`,
  `integration_listener_execution.jl`, `regression_executor_failure.jl`:
  real child processes, startup/stop failure, execution, callbacks, and child death.
- `integration_executor_cache_clear.jl`, `integration_executor_restart.jl`,
  `unit_server_management_protocol.jl`, `integration_restart_cli.jl`:
  public single-node controls and CLI results.
- `unit_conductor_restart_operation.jl`, `regression_conductor_restart_all.jl`,
  `unit_conductor_restart_protocol.jl`, `integration_restart_all_cli.jl`:
  maintenance exclusion, every configured target, partial results, operation-ID
  recovery, timeout, and dispatch quarantine after an unknown restart outcome.
- `integration_restart_package_reload.jl`: public V1 → cache clear → V1 →
  executor restart → V2, with precompilation enabled and disabled.
- `integration_conductor_executor_restart.jl`,
  `integration_conductor_restart_all.jl`: real local conductor/listener/executor
  processes, BUSY retention without consuming a retry, four-task batches,
  two-listener replacement, and an unreachable third endpoint.
- `integration_listener_shutdown.jl`: real direct/wrapper entrypoints with
  default and four-thread settings; idle/busy q, EOF, parent SIGINT and isolated
  process-group SIGINT; repeated signals; callbacks, child reaping, and port reuse.
  Unix-only signal injection is explicitly skipped on other platforms.

Known successful precompile messages and deliberate failure diagnostics are
captured and checked inside the relevant fixtures. The outer suite's empty-stderr
requirement is unchanged. `fixtures/shutdown_hook_probe.jl` preserves the rejected
atexit/self-wait diagnosis; it is not a passing regression and is not run by the suite.
The positive event-based signal fixture is exercised by the shutdown regression.

These tests establish local protocol and process-lifecycle behavior, not real MDO
optimization correctness or deployment to production LAN nodes. See
[executor restart operations](EXECUTOR_RESTART.md) for the operational boundary.

Validation receipt for the listener/executor restart change (Julia 1.12.3/macOS):
35 isolated files exited 0 with empty stderr; their printed assertions totaled
2,557 passes, plus 70 parent checks (2,627 combined), in 4m09.4s. This includes
607 shutdown checks. These are observed counts, not fixed expectations for
future runs; some race tests make a different number of assertions depending on
which reservation wins. Detailed records are in the
[completed restart Todo](../history/TODO_syncopade_listener_executor_restart.md).

## 4. Run one-PC integration tests

Open 3 terminals in project root.

Terminal A:
```bash
julia syncopadeServer.jl
```

Terminal B:
```bash
julia syncopadeConductor.jl
# Equivalent wrapper entrypoint:
julia scripts/run_conductor.jl
```

Terminal C:
```bash
julia test/integration_single_pc.jl
```

Expected behavior:
- Conductor logs queued and dispatched task.
- Server executes `testScript4syncopade.test_syncopade`.
- Terminal C receives callback and prints `integration_single_pc passed`.

For the current lan100 four-task regression, point the server mount root at the
test fixture and use only `192.168.100.30`. This manual recipe assumes an isolated
test environment: the selected profile may contain other nodes. Do not run it
against a conductor serving unrelated work, and verify the stated `LIST`
precondition before submitting anything:

Terminal A:
```bash
SYNCOPADE_NODE_PROFILE=lan100 \
SYNCOPADE_WIRED_PREFIX=192.168.100. \
SYNCOPADE_MOUNT_ROOT_UNIX="$PWD/test/fixtures" \
julia --startup-file=no --project=. scripts/run_server.jl
```

Terminal B:
```bash
SYNCOPADE_NODE_PROFILE=lan100 \
SYNCOPADE_WIRED_PREFIX=192.168.100. \
SYNCOPADE_CONDUCTOR_LOG=/tmp/syncopade-conductor.csv \
julia --startup-file=no --project=. scripts/run_conductor.jl
```

Terminal C (after `LIST` contains only `192.168.100.30:8030`):
```bash
julia --startup-file=no --project=. \
  test/integration_conductor_node_exclusivity.jl \
  192.168.100.30 9030 192.168.100.30 8030 \
  4 9260 1.0 30.0 /tmp/syncopade-conductor.csv
```

The success marker is `STEP11_RESULT=PASS_LAN100_EXCLUSIVE_TERMINAL`.
All four callbacks must use `TASK_RESULT`, match the submitted task IDs, and
match four `WORKER_DONE_OK` status responses. Worker execution intervals must
not overlap and `max_active` must remain 1. A BUSY response may occur depending
on timing; deterministic BUSY retention is covered by
`test/regression_conductor_busy_wait.jl`.

Stop the server with `q` and the conductor with SIGINT. Verify ports 8030, 9030,
and the four callback ports can be rebound after shutdown.

`test/integration_server_busy_acceptance.jl` is a preserved pre-fix harness
that expects the old overlapping behavior. It is historical evidence, not a
current regression test, and is intentionally excluded from `test/runtests.jl`.
Use `test/integration_server_busy_rejection.jl` for the current one-server
admission contract.

Conductor entrypoint contract:
- Direct execution of `syncopadeConductor.jl` starts `main()` through its
  `PROGRAM_FILE` guard.
- Direct execution of `scripts/run_conductor.jl` includes the conductor
  definitions and then calls `main()` explicitly.
- Including `syncopadeConductor.jl` from tests or another Julia file only loads
  definitions; callers that want to start the conductor must call `main()`.

Server entrypoint contract:

- Direct execution of `syncopadeServer.jl` starts `main()` through its
  `PROGRAM_FILE` guard.
- Direct execution of `scripts/run_server.jl` includes the server definitions
  and calls `main()` through its own `PROGRAM_FILE` guard.
- Including either file only loads definitions: no listener, executor, or
  process-wide SIGINT watcher is started.
- With no arguments, the configured profile/fallback selection is unchanged.
  `--bind IP --port PORT` selects an explicit endpoint; both arguments are required.
  Port 0 lets the OS assign a free port, printed in the bind-address line.
- q/EOF stop admission, wait for accepted work and notifications, stop/reap the
  child, and exit 0. Ctrl-C requests the same cleanup and then exits 130; it does
  not inject an exception into the result receiver. Repeated Ctrl-C is coalesced.
  A hung calculation is not forcibly killed by this graceful shutdown.
- The SIGINT watcher uses Julia's bundled libuv and Base's event-loop/I/O-lock
  helpers only in the CLI. The executor is in a separate process group. Library
  callers should use `syncopade_server` / `stop_listener!`, not run CLI `main`
  inside a long-lived REPL. Those library calls do not replace signal handling.

For an explicitly local server (without contacting a configured LAN):

```bash
julia --startup-file=no --project=. scripts/run_server.jl --bind 127.0.0.1 --port 8030
```

Shutdown/restart verification was performed on Julia 1.12.3/macOS. This is not
evidence of Windows console behavior, Linux behavior, or other Julia versions;
repeat these tests there before deployment, especially when upgrading Julia.

## 5. Example scripts

If you want command examples first (instead of tests):

```bash
julia examples/01_basic_server_client.jl
julia examples/02_conductor_list.jl
julia examples/03_submit_dispatch_retry.jl
```

Each example accepts optional positional arguments.
- `01`: `server_ip server_port callback_port`
- `02`: `conductor_ip conductor_port`
- `03`: `conductor_ip conductor_port callback_port`

## 6. Node Profile / LAN selection memo

Node lists are now managed in `syncopadeNodeConfig.jl`.
- Profile `lan12`: `192.168.12.*` nodes (default)
- Profile `lan100`: `192.168.100.*` nodes

Select network profile with `SYNCOPADE_NODE_PROFILE` when starting both server and conductor:

```bash
# default (lan12)
julia syncopadeServer.jl
julia syncopadeConductor.jl

# use 192.168.100.* list
SYNCOPADE_NODE_PROFILE=lan100 julia syncopadeServer.jl
SYNCOPADE_NODE_PROFILE=lan100 julia scripts/run_server.jl
SYNCOPADE_NODE_PROFILE=lan100 julia syncopadeConductor.jl
SYNCOPADE_NODE_PROFILE=lan100 julia scripts/run_conductor.jl
```

Server behavior:
- `syncopadeServer.jl` picks a bind target from the selected profile.
- It tries profile entries in order and uses the first local IP that can be bound.
- If none can be bound, it falls back to `getipaddr()` behavior.
