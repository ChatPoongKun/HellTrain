"""Exercise follow-up effects through projection, presentation and pending commit."""
import argparse
from simulate_balance import HERE, runtime


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--engine', choices=['lua54', 'jit'], default='lua54')
    parser.add_argument('--matchups', action='store_true', help='Also validate pending generation for all 20 demo matchups')
    args = parser.parse_args()
    lua, _ = runtime(args.engine)
    lua.execute((HERE / 'check_followup.lua').read_text(encoding='utf-8'))
    print(f'PASS: {args.engine}, follow-up boundaries, ordering, victory, pending/reuse/commit and invalid events')
    if args.matchups:
        lua.execute((HERE / 'simulate_balance.lua').read_text(encoding='utf-8'))
        lua.execute('''
            local originalChecked = checked
            function checked(name, action, ...)
                local result = originalChecked(name, action, ...)
                if name == "turnResolver" and action == "resolveTurn" then
                    local args = {...}
                    originalChecked("battleRuntime", "preparePending", args[1], args[2], args[3])
                end
                return result
            end
        ''')
        for style in ('predator', 'harmonizer', 'glutton', 'deceiver'):
            for character in sorted(lua.globals().data.characters):
                lua.globals().oneBattle(style, character, 20365635)
                print(f'PASS: pending generation for {style} / {character}', flush=True)


if __name__ == '__main__':
    main()
