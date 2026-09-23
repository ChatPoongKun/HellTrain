# Character-local card data

The approved direction is to store cards with their character and avoid loading
every character during ordinary setup and battle interactions. Preserve card IDs,
save formats, battle rules, discovery records, and deterministic selection.

- Each `Char/<Character>.db` owns its profile, deck, and `cards` collection.
- `CharacterList.db` remains the small catalog: ID, DB name, display name and
  turn limit. These summary fields support deterministic session replay without
  loading old opponents. Full validation checks summaries against definitions.
- A small shared card support DB contains constructors/helpers, never cards.
- `staticData.loadCatalog` returns common data and catalog summaries.
  `loadCharacters(ids)` adds only the requested definitions/cards. Cache keys
  include the sorted requested IDs; callers receive independent snapshots.
- Setup and progression use the catalog. Views hydrate displayed candidates.
  Battle loads the current opponent; handoff may temporarily need old and new
  opponents for retirement validation. No lazy metatables are introduced.
- Explicit whole-card codex opening and developer `loadAll`/`validateAll` retain
  full loading. Ordinary codex recording preserves unloaded discoveries.
- Build/release validation still checks all character definitions, duplicate IDs,
  deck references and catalog consistency. Packaged CHARX includes all content;
  this change reduces Lua loading/copying, not the host's package size.

Acceptance: unchanged full regression results in Lua 5.4 and LuaJIT; catalog
loads no character DB, single-character loads no other character DB; scope
switches and caller mutation never pollute caches; unrelated malformed character
content affects full validation but not another character's scoped load.
