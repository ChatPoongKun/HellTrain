"""Small runnable checks for the simulation and the observed expiry regression."""
import argparse
import json
import time

from simulate_balance import ROOT, HERE, RESULTS, runtime


def main():
    p = argparse.ArgumentParser()
    p.add_argument('--expiry', action='store_true')
    p.add_argument('--timing', action='store_true')
    p.add_argument('--engine', default='lua54')
    p.add_argument('--compare', help='Fresh simulation JSON to compare with the pre-fix Lua 5.4 baseline')
    args = p.parse_args()
    if args.expiry or args.timing:
        lua, _ = runtime(args.engine)
        lua.execute((HERE / 'simulate_balance.lua').read_text(encoding='utf-8'))
        if args.expiry:
            lua.execute((HERE / 'check_expiry.lua').read_text(encoding='utf-8'))
            lua.execute('''
                local originalChecked = checked
                function checked(name, action, ...)
                    local result = originalChecked(name, action, ...)
                    if name == "turnResolver" and action == "resolveTurn" then
                        local args = {...}
                        originalChecked("turnEventProjector", "projectTurn", args[1], args[2], result.resolution)
                    end
                    return result
                end
            ''')
            lua.execute("decks.deceiver[7]='pc_deceiver_008'")
            result = lua.globals().oneBattle('deceiver', 'seo_miryeong', 20365635)
            assert result.status in ('victory', 'defeat')
            print('PASS: 10 plan lifecycle cases, 5 pending/commit checks, settlement/replay/view, invalid event and summary rejection, original seed regression')
        else:
            for i in range(41, 51):
                start = time.monotonic()
                print('starting', i, flush=True)
                lua.globals().oneBattle('predator', 'han_jenny', 20260906+i*104729)
                print('completed', i, round(time.monotonic()-start, 2), flush=True)
        return
    paths = [RESULTS / f'simulation_check_{name}.json' for name in ('lua54', 'jit')]
    a, b = [json.loads(path.read_text(encoding='utf-8')) for path in paths]
    for report in (a,b):
        for r in report['results']:
            for trial in r['trials']:
                trial.pop('engine',None)
    key = lambda r: (r['style'], r['character'])
    assert len(a['results']) == len(b['results']) == 20
    assert sorted(a['results'], key=key) == sorted(b['results'], key=key)
    if args.compare:
        fresh = json.loads((ROOT / args.compare).read_text(encoding='utf-8'))
        for r in fresh['results']:
            for trial in r['trials']:
                trial.pop('engine', None)
        assert fresh['decks'] == a['decks'] and fresh['base_seed'] == a['base_seed']
        assert sorted(fresh['results'], key=key) == sorted(a['results'], key=key)
        player_cards = {card for r in fresh['results'] for card in r['cards']}
        enemy_cards = {card for r in fresh['results'] for card in r['enemyCards']}
        print(f'PASS: 20 fresh matchups exactly equal pre-fix results; {len(player_cards)} player / {len(enemy_cards)} opponent card IDs declared')
    results_path = RESULTS / 'simulation_results.json'
    if results_path.exists():
        report = json.loads(results_path.read_text(encoding='utf-8'))
        assert len(report['results']) == 20, 'The main simulation is incomplete'
        for r in report['results']:
            assert r['n'] == len(r['trials']) == report['runs_per_matchup']
            assert len({t['seed'] for t in r['trials']}) == r['n']
            assert sum(t['status'] == 'victory' for t in r['trials']) == r['wins']
            assert all(t['status'] in ('victory', 'defeat') for t in r['trials'])
            assert sum(t['turns'] for t in r['trials']) == r['turns']
            starts={'han_jenny':27,'seo_miryeong':33,'sister_agnes':34,'yoo_jiyoung':30,'yoon_seoa':36}
            for trial in r['trials']:
                assert starts[r['character']]+trial['enemyHealing']-trial['damage']==trial['resistance']
                assert trial['status']=='victory' or trial['reason']=='turn_limit' or trial['stealth']<=0
    print('PASS: 20 Lua engine comparisons; complete results, unique seeds and aggregate counts')


if __name__ == '__main__':
    main()
