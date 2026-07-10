function (triggerId)


--임시 카드 선택 ui. 덱 구성을 구현한 후 보유한 덱에서 무작위로 불러와 내용을 조립하도록 해야 함.
local cardUI = [[<div class="card-container">
<input class="card-state" type="radio" name="selected-card" id="card-none-state" checked>
<div class="card-slot">
<input class="card-state" type="radio" name="selected-card" id="card-1-state">
<label class="card" for="card-1-state">
<div class="card-header">
<div class="card-icon">🗡️</div>
<div class="card-title">
성기사의 대검
<span>근접 무기 / 양손</span>
</div>
<div class="card-badge">EPIC</div>
</div>
<div class="card-body-wrapper">
<div class="card-body">
<div class="card-body-content">
빛의 신성한 힘이 깃든 거대한 검입니다. 언데드 계열 적에게 추가 피해를 입힙니다.
<div class="stats-grid">
<div class="stat-item">
<strong>+120</strong>
공격력
</div>
<div class="stat-item">
<strong>+45</strong>
신성 피해
</div>
</div>
</div>
</div>
</div>
</label>
<label class="card-activate" for="card-none-state" risu-btn="card_1"></label>
</div>
<div class="card-slot">
<input class="card-state" type="radio" name="selected-card" id="card-2-state">
<label class="card" for="card-2-state">
<div class="card-header">
<div class="card-icon">🔮</div>
<div class="card-title">
심연의 수정구
<span>마법 도구 / 한손</span>
</div>
<div class="card-badge">LEGENDARY</div>
</div>
<div class="card-body-wrapper">
<div class="card-body">
<div class="card-body-content">
기이한 보주입니다. 통찰력을 주지만 정신력을 갉아먹습니다. 마나 재생 속도가 대폭 상승합니다.
<div class="stats-grid">
<div class="stat-item">
<strong>+300%</strong>
마나 재생
</div>
<div class="stat-item">
<strong>-5</strong>
초당 정신력
</div>
</div>
</div>
</div>
</div>
</label>
<label class="card-activate" for="card-none-state" risu-btn="card_2"></label>
</div>
<div class="card-slot">
<input class="card-state" type="radio" name="selected-card" id="card-3-state">
<label class="card" for="card-3-state">
<div class="card-header">
<div class="card-icon">🛡️</div>
<div class="card-title">
불사의 방패
<span>방어구 / 유물</span>
</div>
<div class="card-badge" style="color:#ff3366;background:rgba(255,51,102,0.1);border-color:rgba(255,51,102,0.3);">MYTHIC</div>
</div>
<div class="card-body-wrapper">
<div class="card-body">
<div class="card-body-content">
파괴되지 않는 전설의 방패. 치명적인 피해를 입었을 때 한 번 체력을 모두 회복시키고 무적 상태가 됩니다.
<div class="stats-grid">
<div class="stat-item" style="grid-column:1 / -1;">
<strong style="color:#ff3366;">1회 부활 및 무적</strong>
특수 능력
</div>
</div>
</div>
</div>
</div>
</label>
<label class="card-activate" for="card-none-state" risu-btn="card_3"></label>
</div>
</div>
]]

    setChatVar(triggerId, "cardUI", cardUI)
end