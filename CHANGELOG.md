# Changelog for AgentMap v1.0.0

## v1.0.0

### Enhancements

  * Docs and examples are rewrited;
  * `update`, `cast`, `put`, `replace` and `replace!` calls now returns their
    first arguments (`agentmap`) without changes to support piping;
  * From now on `take/2`, `drop/2`, `delete/2`, `pop/2`, `put/2`, `fetch/2` and
    `fetch!/2` supports `:!` option to be given;

  * Callbacks could read corresponding keys from their process dictionary using
    `Process.get("$key")`. And ask if the value given as an argument in `get`,
    `update`, `cast` or `get_and_update` call exists with
    `Process.get("$has_value?")`. Else you can not differ `nil` value from key not
    exists.
  * Transactional callbacks could use analogous trick: `Process.get("$map")`
    returns `Map` with keys and values that are in `agentmap`, and
    `Process.get("$keys")` returns `keys` list given.
  * Single key transactions will be more effective as they will not create
    additional processes.
  * If selective receive became turned off for worker, warning is emitted.
  * `take/2`, `value/2` and all `Enum` function will load server a little bit
    less.

### New macroses

  * New `safe` macros that wraps given callback to prevent it's bad exit or
    uncatched throw from influence the agentmap process.
  * New `deadline` macros that wraps given callback and prevents it's execution
    if it's still in execution queue while it's time is up. Without it system
    just exits the caller. Deadline can be hard — killing callback that is still
    executing while it's time is up.
