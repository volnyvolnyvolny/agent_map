# Changelog for AgentMap v1.0

## v1.0.0

Complete rewrite.

## v1.0.2

### Enhancements

  * [AgentMap] `get_prop(am, :size)` is optimized. From now it may temporary
    behave a little unaccurate upwards (in some rare cases).
  * [AgentMap] new `tiny: true` option for `get_and_update4`, `update/4`,
    `update!/4`, `cast/4` and `put_new_lazy/4`;
  * [AgentMap] new `upd_prop/4` call;
  * [AgentMap.Multi] `get_and_update/4`, `update/4`, `cast/4` are now have a
    fixed priority `{:avg, +1}`

  * [Docs] Fixing some typos.
  * [Docs] Simplifying, hiding non-interesting aspects.
  * [Docs] New "How it works" section.

### Hard-deprecations

  * [AgentMap] `size/1` is deprecated in favour of `Enum.count/1` and
    `get_prop(am, :size)`.


### Bug fixes

  * [AgentMap] `max_processes` does not allows to provide `nil`.
