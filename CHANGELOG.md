# Changelog for AgentMap v1

## v1.1.2

### Enhancements

#### AgentMap.Utils

  * [rename] `upd_prop/4` → `upd_meta/4`
  * [rename] `get_prop/2` → `meta/2`
  * [rename] `set_prop/3` → `put_meta/4`

### Hard-deprecations

  * [AgentMap.Utils] deprecating `upd_prop/4`, `get_prop/2`, `set_prop/3`.
  * [AgentMap.Utils] deprecating rudimentary `safe_apply/2` `safe_apply/3`.

## v1.1.1

### Enhancements

#### Docs

  * [README.md] Quickfix for the confusing example (sorry, "I noticed not the
    elephant at all").

## v1.1

### Enhancements

  * [AgentMap.Utils] new (and single) option for `upd_prop/4` — `cast: false`.

## v1.1-rc.1

### Hard-deprecations

  * [AgentMap.Utils] `upd_prop/4` is now hard deprecated.
  * [AgentMap.Utils] `get_prop/4` is now hard deprecated.

## v1.1-rc.0

### Enhancements

#### AgentMap

  * [optimized] `get_prop(am, :size)` executes fast, but may behave a little
    unaccurate upwards (rare cases);
  * [new] `get_prop(am, :real_size)` a little slower version of above call, but
    accurate;

  * [new option] `tiny: true`, for `get/4`, `get_and_update4`, `update/4`,
    `update!/4`, `cast/4` and `put_new_lazy/4`;
  * [new options] `:default`, `:timeout` and `:!` for `get/3`.

  * [moved] to `AgentMap.Utils`: `get_prop/3`, `set_prop/3`;
  * [moved] to `AgentMap.Utils`: `inc/3`, `dec/3`;
  * [moved] to `AgentMap.Utils`: `safe_apply/2,3`, `sleep/4`.

  * [loose] `values/2` now has a single argument (no priority option).
  * [loose] `to_map/2` now has a single argument (no priority option).

  * [decided] that `take/3` will have default `:now` priority.

#### AgentMap.Utils

  * [new] Introduced.
  * [new] `upd_prop/4` call;

  * [moved in] from `AgentMap`: `get_prop/3`, `set_prop/3`;
  * [moved in] from `AgentMap`: `inc/3`, `dec/3`;
  * [moved in] from `AgentMap`: `safe_apply/2,3`, `sleep/4`.

#### AgentMap.Multi

  * [decided] `get_and_update/4`, `update/4`, `cast/4` are now have a fixed
    priority `{:avg, +1}`.

  * [new option] `:get` for `get_and_update/4`, `update/4` and `cast/4` methods.
  * [new options] `:default`, `:timeout` and `:!` for `get/3`.

#### Docs

  * Fixing some typos.
  * Simplifying, hiding non-interesting aspects.

  * [new] "How it works" section.

### Hard-deprecations

  * [AgentMap] `size/1` is deprecated in favour of `Enum.count/1` and
    `get_prop(am, :size)`.

  * [AgentMap] `update/5` in favor of using the `:initial` option.
  * [AgentMap] `pid/1` is deprecated in favour of using `am.pid` :).
  * [AgentMap] `max_processes/3` is deprecated.
  * [AgentMap] `info/3` is deprecated.

  * [AgentMap] `get_lazy/4`. It may return later in form of a whole new `:lazy`
    option wherever `:initial` option is applicable.

### Bug fixes

  * Workers never received `:continue`.

## v1.0.0

Complete rewrite.
