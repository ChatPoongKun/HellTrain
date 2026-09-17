"""Validate real card callback commands across moods and boundary contexts."""
from pathlib import Path
import sys
sys.path.insert(0,str(Path('build/tests/BattleSimulation/StyleDecks').resolve()))
from simulate_balance import runtime
lua,_=runtime(sys.argv[1] if len(sys.argv)>1 else 'lua54')
lua.execute(r'''
local moods={'rejection','suspicion','ignore','confusion','compliance'}
local counts={cards=0,contexts=0,callbacks=0}
local function check(label,report)
 assert(report.ok,label..': '..(report.errors[1] and report.errors[1].code..' '..report.errors[1].message or '?'))
 counts.callbacks=counts.callbacks+1
 return report
end
local function engine(action,...) return runScript('audit','effectEngine',action,data,...) end
for id,card in pairs(data.cards) do
 counts.cards=counts.cards+1
 for _,mood in ipairs(moods) do
 for _,n in ipairs({0,1,4,5,12,13,18,19,30}) do
  local tokens={} for _,m in ipairs(moods) do tokens[m]=n end
  local context={mood=mood,turn=1,turnLimit=9,remainingTurns=n,phase='player_card',
   player={stealth=n,handCount=n,planCount=n>0 and 1 or 0},
   character={resistance=n,moodTokens=tokens,planCount=n>0 and 1 or 0,publicRole='recovery'},
   playerChainCardsResolved=n,card={id=id,owner=card.owner,roles=card.roles},
   plan={remainingTurns=math.max(1,n),remainingCharges=math.max(1,n)},
   history={previousTurn=n>0 and {startMood='rejection',endMood=mood} or nil}}
  counts.contexts=counts.contexts+1
  check(id..' canPlay',engine('evaluateCanPlay',id,context))
  if card.narrationCondition then check(id..' condition',engine('evaluateNarrationCondition',id,context)) end
  if card.effectChoices then
   for _,choice in ipairs(card.effectChoices) do
    context.effectChoiceId=choice.id
    local selectable=check(id..' choice',engine('evaluateEffectChoice',id,choice.id,context)).selectable
    if selectable then check(id..' resolve '..choice.id,engine('evaluateCardResolve',id,context)) end
   end
   context.effectChoiceId=nil
  else check(id..' resolve',engine('evaluateCardResolve',id,context)) end
  for _,m in ipairs(moods) do check(id..' mood',engine('evaluateMoodEffect',id,m,context)) end
  local plan=card.mechanismData and card.mechanismData.plan
  if plan then
   local event={type=plan.event or 'card_declared',side=plan.side or 'player',roles={'violation','pressure','deception','recovery'},
    finalResistanceDamage=n,finalStealthRecovery=n,finalResistanceRecovery=n,cardId=id,instanceId='audit-card'}
   check(id..' trigger',engine('evaluateTriggerCondition',plan,context,event))
   check(id..' plan resolve',engine('evaluateTriggerResolve',plan,context,event))
   if plan.exitResolve then
    local commands=plan.exitResolve(context,event)
    check(id..' exit',engine('validateCommands',commands))
   end
  end
 end
 end
end
print('card callback contracts:',counts.cards,'cards,',counts.contexts,'contexts,',counts.callbacks,'validated callbacks')
''')

