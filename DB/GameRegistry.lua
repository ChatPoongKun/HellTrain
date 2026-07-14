return {
    schemaVersion = 1,
    kind = "gameRegistry",

    actionTags = {
        observation = {
            id = "observation",
            owner = "player",
            label = "관찰",
            tooltip = "상대와 주변 상황에서 정보를 얻는 행동",
        },
        approach = {
            id = "approach",
            owner = "player",
            label = "접근",
            tooltip = "상대와 거리를 좁히거나 다음 행동을 준비하는 행동",
        },
        deception = {
            id = "deception",
            owner = "player",
            label = "기만",
            tooltip = "의도와 관심을 숨기거나 상대의 판단을 흐리는 행동",
        },
        threat = {
            id = "threat",
            owner = "player",
            label = "위협",
            tooltip = "상대를 강하게 압박하는 행동",
        },
        contact = {
            id = "contact",
            owner = "player",
            label = "접촉",
            tooltip = "신체 접촉을 시도하는 행동",
        },
        violation = {
            id = "violation",
            owner = "player",
            label = "유린",
            tooltip = "상대의 의사를 무시하고 강제로 행하는 행동",
        },
        evade = {
            id = "evade",
            owner = "character",
            label = "회피",
            tooltip = "몸을 피하거나 거리를 벌리는 행동",
        },
        block = {
            id = "block",
            owner = "character",
            label = "차단",
            tooltip = "몸이나 옷을 가려 상대의 행동을 막는 행동",
        },
        vigilance = {
            id = "vigilance",
            owner = "character",
            label = "경계",
            tooltip = "상대의 움직임을 주시하고 경고하는 행동",
        },
        intimidate = {
            id = "intimidate",
            owner = "character",
            label = "협박",
            tooltip = "말이나 태도로 상대가 행동하기 어렵게 만드는 행동",
        },
        expose = {
            id = "expose",
            owner = "character",
            label = "폭로",
            tooltip = "주변에 상황을 알리거나 플레이어의 행동을 드러내는 행동",
        },
    },

    mechanisms = {
        chain = {
            id = "chain",
            label = "연계",
            tooltip = "주 행동을 소비하지 않는 준비 행동",
        },
        remove = {
            id = "remove",
            label = "제거",
            tooltip = "사용 후 이번 세션의 활성 카드 영역에서 제외",
        },
        plan = {
            id = "plan",
            label = "계획",
            tooltip = "계획 슬롯에 배치되어 조건을 만족하면 발동",
        },
        insight = {
            id = "insight",
            label = "간파",
            tooltip = "이 카드 때문에 발동할 상대 계획을 이번 해결에서 억제",
        },
    },

    moods = {
        rejection = { id = "rejection", label = "거절", order = 1 },
        suspicion = { id = "suspicion", label = "의심", order = 2 },
        ignore = { id = "ignore", label = "무시", order = 3 },
        confusion = { id = "confusion", label = "혼란", order = 4 },
        compliance = { id = "compliance", label = "순응", order = 5 },
    },

    events = {
        sessionStart = { id = "sessionStart" },
        turnStart = { id = "turnStart" },
        actionTagRevealed = { id = "actionTagRevealed" },
        cardDeclared = { id = "cardDeclared" },
        cardResolved = { id = "cardResolved" },
        turnEnd = { id = "turnEnd" },
        sessionEnd = { id = "sessionEnd" },
    },

    effectOps = {
        damageResistance = { id = "damageResistance" },
        recoverResistance = { id = "recoverResistance" },
        loseStealth = { id = "loseStealth" },
        recoverStealth = { id = "recoverStealth" },
        drawCards = { id = "drawCards" },
        skipActions = { id = "skipActions" },
        shiftMood = { id = "shiftMood" },
        setMood = { id = "setMood" },
        lockMood = { id = "lockMood" },
    },
}
