## 碧水沃野植物数据模型（规则书 §5）
##
## 三种植物 + 三种形态 + 每棵植物独立绑定 (species, owner) + 与 tile_cell 强绑定。
## land_region_id 由 PlantEngine.analyze() 在每次结算时回填（同一个 tile 可能落在不同的 land_region）。
class_name Plant
extends RefCounted

enum Species {
	GRASS,   # 草，需水量 0.5，计分权重 1
	FLOWER,  # 花，需水量 1.0，计分权重 2
	TREE,    # 树，需水量 2.0，计分权重 4
}

enum Form {
	HEALTHY,      # 健康（V_L ≥ need）—— §5.3
	WATER_SHORT,  # 缺水（V_L < need）—— §5.4 可逆
	WITHERED,     # 枯萎（封闭结算或终局升级）—— §5.3 / §5.6 / §5.7 不可逆
}

## 物种 → 需水量（单地块），按规则书 §5.2
const NEED := {
	Species.GRASS: 0.5,
	Species.FLOWER: 1.0,
	Species.TREE: 2.0,
}

## 物种 → 计分权重（终局 §6.1）
const SCORE_WEIGHT := {
	Species.GRASS: 1,
	Species.FLOWER: 2,
	Species.TREE: 4,
}

## 物种 → 中文显示名
const SPECIES_LABEL := {
	Species.GRASS: "草",
	Species.FLOWER: "花",
	Species.TREE: "树",
}

const FORM_LABEL := {
	Form.HEALTHY: "健康",
	Form.WATER_SHORT: "缺水",
	Form.WITHERED: "枯萎",
}


var id: int = -1                     # 全局唯一 id，由 BoardState 分配
var species: int = Species.GRASS
var owner: int = -1                  # 玩家编号（0 / 1）
var tile_cell: Vector2i = Vector2i.ZERO
var land_region_id: int = -1         # PlantEngine.analyze() 在每次结算时回填（首次种时为 -1）
var form: int = Form.HEALTHY         # 当前形态
var expansion_order: int = -1        # §5.8 扩张顺序字段，§7.2.3 末尾由调用方写入


static func need_for(species: int) -> float:
	return NEED.get(species, 1.0)


static func weight_for(species: int) -> int:
	return SCORE_WEIGHT.get(species, 1)


static func species_label(species: int) -> String:
	return SPECIES_LABEL.get(species, "?")


static func form_label(form: int) -> String:
	return FORM_LABEL.get(form, "?")


func describe() -> String:
	return "Plant{id=%d %s@%s owner=P%d form=%s lr=%d}" % [
		id,
		species_label(species),
		str(tile_cell),
		owner + 1,
		form_label(form),
		land_region_id,
	]
