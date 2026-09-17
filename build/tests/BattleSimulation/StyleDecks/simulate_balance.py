"""Run the repository Lua rules with a small file-backed Risu host shim.

Requires Python 3.12+ and lupa (installed by build/setup.bat).
"""
import argparse
from concurrent.futures import ProcessPoolExecutor, as_completed
import hashlib
import json
from pathlib import Path
import sys
import time

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[3]
RESULTS = HERE / 'results'
from lupa.luajit21 import LuaRuntime, lua_type


def plain(value):
    if hasattr(value, 'items'):
        items = list(value.items())
        if items and all(isinstance(k, int) for k, _ in items):
            return [plain(value[i]) for i in range(1, len(items) + 1)]
        return {k: plain(v) for k, v in items if lua_type(v) != 'function'}
    return value


def runtime(engine='jit'):
    if engine == 'lua54':
        from lupa.lua54 import LuaRuntime as Engine
    else:
        Engine = LuaRuntime
    lua = Engine(unpack_returned_tuples=True)
    sources = {p.name: p.read_text(encoding='utf-8-sig')
               for folder in ('System', 'DB', 'Char') for p in (ROOT / folder).iterdir()
               if p.suffix in ('.lua', '.db')}
    lua.globals().sources = lua.table_from(sources)
    lua.execute('''
      local handlers = {}
      function getLoreBooks(_, name) return {{content=assert(sources[name], name)}} end
      function runScript(t, name, action, ...)
        if not handlers[name] then
          handlers[name] = assert(load('return '..assert(sources[name..'.lua'],name),name))()
        end
        return handlers[name](t, action, ...)
      end
      function checked(name, action, ...)
        local r = runScript('simulation', name, action, ...)
        if not r.ok then
          local errors = {}
          for _, e in ipairs(r.errors or {}) do errors[#errors+1]=e.code..' '..e.path..' '..e.message end
          error(name..'.'..action..': '..table.concat(errors, '; '))
        end
        return r
      end
      data = checked('staticData', 'loadAll').data
    ''')
    return lua, sources


_worker_runtime = None


def batch(job):
    global _worker_runtime
    style, character, runs, seed, engine = job
    if _worker_runtime is None:
        lua, _ = runtime(engine)
        lua.execute((HERE / 'simulate_balance.lua').read_text(encoding='utf-8'))
        _worker_runtime = lua
    lua = _worker_runtime
    result = plain(lua.globals().simulate(style, character, runs, seed))
    for trial in result['trials']:
        trial['engine'] = engine
    return result


def merge(target, result):
    for key, value in result.items():
        if isinstance(value, dict):
            merge(target.setdefault(key, {}), value)
        elif isinstance(value, list):
            target.setdefault(key, []).extend(value)
        elif isinstance(value, (int, float)):
            target[key] = target.get(key, 0) + value
        else:
            target[key] = value


def save_json(path, value):
    # Windows readers may briefly hold the destination open. Keep the old checkpoint
    # intact and retry an atomic replacement instead of truncating it in place.
    temporary = path.with_suffix(path.suffix+'.tmp')
    encoded = json.dumps(value, ensure_ascii=False, indent=2)
    for attempt in range(20):
        try:
            temporary.write_text(encoded, encoding='utf-8')
            temporary.replace(path)
            return
        except OSError:
            if attempt == 19:
                raise
            time.sleep(0.1)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--inspect', action='store_true')
    parser.add_argument('--runs', type=int, default=200)
    parser.add_argument('--workers', type=int, default=4)
    parser.add_argument('--engine', choices=['jit', 'lua54'], default='lua54')
    parser.add_argument('--resume', action='store_true')
    parser.add_argument('--seed', type=int, default=20260906)
    parser.add_argument('--style')
    parser.add_argument('--character')
    parser.add_argument('--output', default=str(RESULTS / 'simulation_results.json'))
    args = parser.parse_args()
    assert args.runs > 0 and args.workers > 0
    lua, sources = runtime(args.engine)
    if args.inspect:
        data = lua.globals().data
        for key, card in sorted(data.cards.items()):
            if card.owner == 'player':
                print(json.dumps({k: plain(card[k]) for k in
                    ('id', 'name', 'draftStyle', 'rarity', 'cardType', 'base', 'rules')}, ensure_ascii=False))
        for key, char in sorted(data.characters.items()):
            print(json.dumps({'id': key, 'name': char.name, 'battle': plain(char.battle)}, ensure_ascii=False))
        return
    lua.execute((HERE / 'simulate_balance.lua').read_text(encoding='utf-8'))
    started = time.monotonic()
    results = {}
    output = ROOT / args.output
    if args.resume and output.exists():
        saved = json.loads(output.read_text(encoding='utf-8'))
        assert saved['runs_per_matchup'] == args.runs and saved['base_seed'] == args.seed
        assert saved['decks'] == plain(lua.globals().decks)
        assert saved['source_sha256'] == {k: hashlib.sha256(v.encode()).hexdigest() for k,v in sources.items()}
        rules_hash = hashlib.sha256((HERE/'simulate_balance.lua').read_bytes()).hexdigest()
        assert saved.get('simulation_rules_sha256', rules_hash) == rules_hash, 'simulation policy changed'
        results = {(r['style'], r['character']): r for r in saved['results']}
        for r in results.values():
            for trial in r['trials']:
                trial.setdefault('engine', 'jit' if saved['lua_version']=='Lua 5.1' else 'lua54')
    jobs = []
    for style in ('predator', 'harmonizer', 'glutton', 'deceiver'):
        if args.style and args.style != style:
            continue
        for character in sorted(lua.globals().data.characters):
            if args.character and args.character != character:
                continue
            for offset in range(0, args.runs, 10):
                seeds = {(args.seed+(offset+i)*104729)%2147483646 for i in range(1,min(10,args.runs-offset)+1)}
                present = {t['seed'] for t in results.get((style, character), {}).get('trials', [])}
                if seeds <= present:
                    continue
                assert not seeds & present, 'resume requires complete batches'
                jobs.append((style, character, min(10, args.runs-offset), args.seed+offset*104729, args.engine))
    with ProcessPoolExecutor(max_workers=args.workers) as pool:
        futures = [pool.submit(batch, job) for job in jobs]
        for future in as_completed(futures):
            try:
                result = future.result()
            except BaseException:
                for pending in futures:
                    pending.cancel()
                raise
            key = (result['style'], result['character'])
            merge(results.setdefault(key, {}), result)
            combined = results[key]
            print(f"{key[0]} / {key[1]}: {combined['n']}/{args.runs}, wins={combined['wins']}", flush=True)
            output = ROOT / args.output
            output.parent.mkdir(parents=True, exist_ok=True)
            save_json(output, {'runs_per_matchup': args.runs, 'base_seed': args.seed,
                'elapsed_seconds': time.monotonic()-started, 'lua_version': lua.eval('_VERSION'),
                'engines': sorted({t['engine'] for r in results.values() for t in r['trials']}),
                'simulation_rules_sha256': hashlib.sha256((HERE/'simulate_balance.lua').read_bytes()).hexdigest(),
                'source_sha256': {k: hashlib.sha256(v.encode()).hexdigest() for k,v in sources.items()},
                'decks': plain(lua.globals().decks), 'results': list(results.values())})


if __name__ == '__main__':
    main()
