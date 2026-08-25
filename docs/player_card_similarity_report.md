# 플레이어 카드 유사성 점검 보고

기준 DB: `DB/PlayerCards.db` (2026-08-26 재설계 반영)

## 높은 유사성

- `p045_press_between_thighs` / `p047_unhesitating_touch`
  - 둘 다 기본 피해 3, 혼란 추가 피해 1, 순응 추가 피해 3이다.
  - p045는 순응 시 냉각 1, p047은 간파를 가져 차이는 있지만 핵심 피해 곡선이 같다.
  - 다음 밸런스 조정 때 둘 중 하나의 무드 조건이나 피해 곡선을 바꾸는 편이 좋다.

## 중간 유사성

- `p005_blame_the_crowd` / `p014_caress_nape`
  - 둘 다 농락 2인 표준 Push다. 행동 태그와 비용·기본 피해가 달라 태그 연계용 구분은 남아 있다.
- `p004_press_from_behind` / `p009_grind_hips`
  - 둘 다 접근·연계·농락 1이다. p004만 비용 1과 부정 무드 은폐 회복을 가져 상위 기능이 겹친다.
- `p007_feign_indifference` / `p017_grope_behind_the_crowd`
  - 둘 다 기만 태그로 손길을 숨기는 묘사다. p007은 Recovery/Deny, p017은 Push/Recovery라 실제 역할은 다르다.
- `p024_pin_by_force` / `p038_twist_arm_behind_back`
  - 둘 다 완력으로 상대를 고정하는 묘사다. p024는 부정 무드 탈출용 제거 카드, p038은 반발을 감수하는 직접 공격이라 효과는 구분된다.

## 계열 유사성

- `p041_reach_under_skirt`, `p045_press_between_thighs`, `p047_unhesitating_touch`
  - 모두 혼란·순응에서 피해가 커지는 Payoff 계열이다.
  - p041은 무드별 비용, p045는 냉각, p047은 간파로 사용감은 다르지만 카드풀에서 이 계열의 비중이 높다.

이번 재설계로 기존 `p018`/`p045`의 허벅지 사이로 파고드는 직접 중복과 `p038`의 Push/Payoff 중복 역할은 제거했다.
