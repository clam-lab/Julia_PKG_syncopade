# Testing Guide

## 1. Purpose
This project has two testing layers:
- Deterministic suite (`test/runtests.jl`): protocol, state, queue, dispatch,
  timeout, callback, and server-admission regressions.
- Manual integration tests: real conductor/server processes on one PC.

The deterministic suite starts every test file in an isolated Julia process.
This prevents conductor registries, log writers, environment variables, and
test helper globals from leaking into the next test.

## 2. File layout
- `examples/01_basic_server_client.jl`: direct client -> server flow.
- `examples/02_conductor_list.jl`: query conductor `LIST` and print available nodes.
- `examples/03_submit_dispatch_retry.jl`: submit task to conductor and wait callback.
- `test/runtests.jl`: isolated deterministic test entrypoint (15 files).
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
test fixture and use only `192.168.100.30`:

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
  and then calls `main()` explicitly.
- Including `syncopadeServer.jl` from tests or another Julia file only loads
  definitions; callers that want to start the server must call `main()`.

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
