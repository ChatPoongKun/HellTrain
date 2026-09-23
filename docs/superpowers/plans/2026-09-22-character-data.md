# Character-local Data Implementation Plan

> Use superpowers:executing-plans to implement inline in this session.

**Goal:** Preserve gameplay while bounding ordinary card loading to needed characters.
**Architecture:** Catalog plus explicit scoped static snapshots; character-owned cards.
**Tech Stack:** Existing Lua, Python/Lupa, PowerShell build checks.
**Spec:** ../specs/2026-09-22-character-data-design.md

## Constraints and review focus

Keep existing IDs, rules and saves. Preserve discoveries from unloaded opponents.
Check cache scope switching, malformed/unregistered IDs, duplicate cards, catalog
drift, and old-to-new battle handoff. Do not add runtime dependencies.

## Tasks

- [x] Add `check_scoped_static_data.py`: compare catalog/scoped/full snapshots,
  captured lore names, cache isolation, error isolation and discovery retention.
  Run with the installed Python and verify the new action fails before edits.
- [x] Move existing card blocks unchanged into the matching character modules;
  extract shared constructors into `CharacterCardSupport.db`; add small summaries
  to `CharacterList.db`. Replace full-only static loading with `loadCatalog()` and
  `loadCharacters(ids)` alongside existing full validation actions.
- [x] Route setup through catalog, candidate/profile rendering through scoped
  loading, and battle through current/transition character IDs. Preserve codex
  stored IDs when their definitions are absent from a scoped snapshot.
- [x] Update build lore metadata, test fixture mappings and taxonomy discovery;
  document explicit full-codex loading and catalog maintenance requirements.
- [x] Run focused checks on Lua 5.4 and LuaJIT, refresh the content revision,
  run the complete release suite, build CHARX, inspect the final diff.

## Execution record

- Checkpoint: `665a7fd` preserves all pre-existing tracked and untracked work.
- Ruling: keep work in the user's current checkout after the requested checkpoint;
  preserve the previously accepted architecture without another approval round.
- RED: scoped regression initially failed on missing `loadCatalog` action.
- GREEN: catalog/scoped loading, cache isolation, invalid inputs, catalog drift,
  200-character expansion and discovery retention pass on Lua 5.4 and LuaJIT.
- A one-off comparison to the checkpoint confirms all non-function fields in
  cards, characters, registry, traits, perks and subway definitions are unchanged.
- Fresh review found journal cache thrashing beyond four individual scopes.
  RED reproduced six validations for catalog + five characters; batching journal
  IDs passes with two cold validations and zero subsequent warm validations,
  without mutating the caller's catalog. No other actionable findings reported.
- Final validation: all 43 release checks pass, including 1,890 perk scenarios,
  325 player-card scenarios and 250 character-card scenarios per Lua runtime.
  `git diff --check` passes. Built `build/HellTrain.charx`; package integrity,
  all packaged lores and the entrypoint match the final workspace sources.
- Final source changes remain in the working tree for inspection; the requested
  pre-refactor checkpoint remains `665a7fd`.
