return {
    schemaVersion = 1,
    kind = "traitDatabase",
    traits = {
        reserved = {
            id = "reserved",
            owner = "character",
            name = "소극적",
            visibility = "public",
            description = "순응 방향으로 무드가 이동하려면 평소보다 1 높은 무드 성과가 필요합니다.",
            rules = {
                "순응 방향 무드 이동에 필요한 무드 성과 기준이 1 증가합니다.",
            },
            modifiers = {
                {
                    timing = "moodPerformanceThreshold",
                    operation = "add",
                    direction = "compliance",
                    amount = 1,
                },
            },
        },
    },
}
