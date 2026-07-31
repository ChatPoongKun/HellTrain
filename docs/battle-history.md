# 전투 이력 계약 v1

`battleState.history`는 완료된 턴만 보존하는 권위 이력이다. 턴 해결은 `turnResolver`에서 기계적 이력을 추가하고, `battleRuntime`에서 비공개 정보를 제거한 `publicResult`를 같은 턴에 연결한 뒤 pending 무결성을 봉인한다.

효과 콜백에는 `context.history`가 제공된다.

```lua
local previousMood = context.history.previousTurn
    and context.history.previousTurn.finish.mood

local previousStealth = context.history.previousTurn
    and context.history.previousTurn.finish.stealth

local sameTag = context.history.player.lastResolvedActionTag
    == context.card.actionTag

local recentContactCount = context.history.windows[3]
    and (context.history.windows[3].player.resolvedTagCounts.contact or 0)
    or 0
```

카드 사용 횟수는 `declaredTagCounts`와 `resolvedTagCounts`를 구분한다. 일반적인 “사용했다” 조건은 `resolvedTagCounts`를 사용한다. `windows[N]`은 N=1..12에 항상 존재하고 직전 완료 N턴까지 포함하며 현재 해결 중인 턴은 포함하지 않는다. 초반에는 `availableTurns`가 실제 존재하는 완료 턴 수를 나타낸다. `previousTurn.start`, `previousTurn.finish`, `previousTurn.mood`에서 직전 턴의 자원·무드·토큰 판정 상태를 읽을 수 있다.

전투가 종료되면 `battleHistory.buildPublicView`가 공개 사건만 텍스트로 투영한다. 종료 전투의 `battleView.battleLog`와 별도로 컨트롤러가 검증된 `battleLogView`를 게시하므로, 즉시 종료와 조기 승리 후 자유행동 종료 모두 `html/postBattle.html` 정산 화면에서 전체 로그를 펼쳐 볼 수 있다.
