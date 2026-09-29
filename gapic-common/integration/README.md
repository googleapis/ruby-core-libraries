# Integration Tests

This directory contains integration tests for `gapic-common`, executed against a running `gapic-showcase` server via the `toys test-integration` command.

## Running Integration Tests

```bash
toys test-integration
```

You can pass standard Minitest flags to filter or seed test runs:

```bash
toys test-integration --name /resumable_upload/ --seed 1234
```

## Showcase Server Management & Lifecycle

The `toys test-integration` command (`.toys/test-integration.rb`) manages the `gapic-showcase` server lifecycle automatically:

1. **Existing Endpoint (`SHOWCASE_ENDPOINT`)**:
   - If `ENV["SHOWCASE_ENDPOINT"]` is present and non-empty, `toys test-integration` skips binary resolution and runs the Minitest suite directly against that endpoint.

2. **Binary Resolution (`SHOWCASE_BIN` / `PATH`)**:
   - When `SHOWCASE_ENDPOINT` is not set, the runner checks `ENV["SHOWCASE_BIN"]` first, then searches `ENV["PATH"]` for an executable `gapic-showcase` binary.
   - **Version Check**: The runner executes `<binary> --version` and verifies that the version is at least `0.43`. If the version is older than `0.43`, it logs an error and exits with status `1`.

3. **Missing Endpoint and Binary**:
   - **CI Environment (`ENV["CI"]` set)**: Fails immediately with exit status `1`.
   - **Local Environment (`ENV["CI"]` unset)**: Logs an informational message and skips integration tests cleanly (exit status `0`).

4. **Ephemeral Port Allocation & Polling**:
   - Allocates two ephemeral TCP ports on `127.0.0.1` for `--port :<port>` and `--fallback-port :<fallback_port>` to avoid port collisions across concurrent runs.
   - Spawns `gapic-showcase run --port :<port> --fallback-port :<fallback_port>` in a dedicated process group (`pgroup: true`) with `stdout` and `stderr` redirected to a temporary log file in `Dir.tmpdir`.
   - Polls `127.0.0.1:<port>` with a 10-second monotonic clock budget while checking `Process.waitpid2` (`WNOHANG`) on each iteration. If the process exits prematurely or fails to accept TCP connections within 10 seconds, the runner prints the path to the log file and exits with status `1`.

5. **Execution & Teardown**:
   - Sets `ENV["SHOWCASE_ENDPOINT"] = "http://localhost:#{port}"` and runs the Minitest suite (`integration/**/*_test.rb`).
   - An `ensure` block sends `SIGTERM` to the entire process group (`-TERM`) and reaps the child process so no background showcase processes are leaked.

## Logging and Diagnostics

Each integration test captures `DEBUG`-level client and driver logs into an in-memory buffer during execution:

- **Automatic Failure Dump**: If a test fails or raises an unhandled exception, the captured trace is automatically dumped to `stderr` during `teardown`.
- **Force Log Dump (`SHOWCASE_LOG`)**: Set `SHOWCASE_LOG=1` (or any non-empty value) to dump the captured trace for all executed tests, including passing ones:

```bash
SHOWCASE_LOG=1 toys test-integration
```

