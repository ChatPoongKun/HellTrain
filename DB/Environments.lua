return {
    schemaVersion = 1,
    kind = "environmentDatabase",
    environments = {
        uncrowded = {
            id = "uncrowded",
            name = "한산함",
            description = "주변의 시선을 피하기 어려워 플레이어가 카드를 선언할 때마다 은폐를 1 잃습니다.",
            rules = {
                "플레이어가 카드를 선언할 때마다 비용과 별개로 은폐를 1 잃습니다.",
            },
            triggers = {
                {
                    event = "cardDeclared",
                    side = "player",
                    resolve = function(context, event)
                        return {
                            {
                                op = "loseStealth",
                                target = "player",
                                amount = 1,
                                cause = "environmentEffect",
                            },
                        }
                    end,
                },
            },
        },
    },
}
