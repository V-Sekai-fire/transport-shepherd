# transport-shepherd

A command-line tool for the workspace's agent fleet that runs the workspace gates, shipped as a self-contained binary.

## What it is for

`gates` runs the workspace's checks, ported to Elixir, by name, and `status`, meant to show the fleet's and the local agent's state from the coordination store, prints a placeholder. The release wraps the Erlang runtime into one binary per platform, so a desk needs nothing else installed to run it.

## Building and running

```sh
mix deps.get
mix gates
mix release shepherd
```

`mix gates` lists the gates and runs one by name without building the binary; `mix release shepherd` builds the binaries.

## Licence

Apache-2.0 OR MIT, at your option. See [LICENSE-APACHE](LICENSE-APACHE) and [LICENSE-MIT](LICENSE-MIT).
