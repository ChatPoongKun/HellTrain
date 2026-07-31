# 전투 이력 계약 v1

`battleState.history`는 완료된 턴만 보존하는 권위 이력이다. 턴 해결은 `turnResolver`에서 기계적 이력을 추가하고, `battleRuntime`에서 비공개 정보를 제거한 `publicResult`를 같은 턴에 연결한 뒤 pending 무결성을 봉인한다.

효과 콜백에는 `context.history`가 제공된다.

```lua
local previousMood = context.history.previousTurn
    and context.history.previousTurn.endMood

local sameTag = context.history.player.lastResolvedActionTag
    == context.card.actionTag

local recentContactCount = context.history.windows[3]
    and (context.history.windows[3].player.resolvedTagCounts.contact or 0)
    or 0
```

카드 사용 횟수는 `declaredTagCounts`와 `resolvedTagCounts`를 구분한다. 일반적인 “사용했다” 조건은 `resolvedTagCounts`를 사용한다. `windows[N]`은 직전 완료 N턴을 포함하며 현재 해결 중인 턴은 포함하지 않는다.

전투가 종료되면 `battleHistory.buildPublicView`가 공개 사건만 텍스트로 투영하고 `battleView.battleLog`에 넣는다. `html/battleui.html`은 이를 접을 수 있는 상세 전투 로그로 표시한다.
