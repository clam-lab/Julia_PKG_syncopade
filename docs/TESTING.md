# Testing Guide

## 1. Purpose
This project now has two testing layers:
- Unit tests (`test/runtests.jl`): protocol and queue logic checks.
- Manual integration test (`test/integration_single_pc.jl`): one-PC end-to-end behavior.

## 2. File layout
- `examples/01_basic_server_client.jl`: direct client -> server flow.
- `examples/02_conductor_list.jl`: query conductor `LIST` and print available nodes.
- `examples/03_submit_dispatch_retry.jl`: submit task to conductor and wait callback.
- `test/runtests.jl`: unit test entrypoint.
- `test/unit_client_protocol.jl`: checksum and parse tests for client protocol.
- `test/unit_conductor_queue.jl`: conductor queue, LIFO, retry, default callback port tests.
- `test/integration_single_pc.jl`: manual one-PC integration smoke test.

## 3. Run unit tests
```bash
julia test/runtests.jl
```

## 4. Run one-PC integration test
Open 3 terminals in project root.

Terminal A:
```bash
julia syncopadeServer.jl
```

Terminal B:
```bash
julia syncopadeConductor.jl
```

Terminal C:
```bash
julia test/integration_single_pc.jl
```

Expected behavior:
- Conductor logs queued and dispatched task.
- Server executes `testScript4syncopade.test_syncopade`.
- Terminal C receives callback and prints `integration_single_pc passed`.

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
SYNCOPADE_NODE_PROFILE=lan100 julia syncopadeConductor.jl
```

Server behavior:
- `syncopadeServer.jl` picks a bind target from the selected profile.
- It tries profile entries in order and uses the first local IP that can be bound.
- If none can be bound, it falls back to `getipaddr()` behavior.
