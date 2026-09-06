## 青菱沃野植物数据模型（规则书 §5）
##
## 三种植物 + 三种形态 + 每棵植物独立绑定 (species, owner) + 与 tile_cell 强绑定。
## land_region_id 由 PlantEngine 在每次结算时回填。一个 tile 可能落在多个
## land_region（中心 EMPTY 的多 land 边 split 卡）；"多土地地块一次种满"通过
## 在同一格上为每个 region 各创建一个 Plant 成员实现（共享 tile_cell、不同 region）。
class_name Plant
extends RefCounted

enum Species {
	GRASS,   # 草，需水量 0.5，计分权重 1
	FLOWER,  # 花，需水量 1.0，计分权重 2
	TREE,    # 树，需水量 2.0，计分权重 4
}

enum Form {
	SURVIVING,  # 存活（闭合结算前的唯一常态）—— §5.3
	HARVESTED,  # 收获（闭合结算时水量足够）—— §5.3 / §5.6 终局
	DEAD,       # 死亡（闭合结算时水量不足）—— §5.3 / §5.6 终局
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
	Form.SURVIVING: "存活",
	Form.HARVESTED: "收获",
	Form.DEAD: "死亡",
}


var id: int = -1                     # 全局唯一 id，由 BoardState 分配
var species: int = Species.GRASS
var owner: int = -1                  # 玩家编号（0 / 1）
var tile_cell: Vector2i = Vector2i.ZERO
var land_region_id: int = -1         # 所属 land_region 的临时 id（每次 analyze 重编号；用 land_subnet_idx 稳定定位）
var land_subnet_idx: int = 0         # 所在格的 land 子网序号（稳定，用于 split 卡一格多 region 时重新定位）
var form: int = Form.SURVIVING         # 当前状态
var expansion_order: int = -1        # §5.8 扩张顺序字段，§7.2.3 末尾由调用方写入
var seed_committed := true            # 主动种植消耗种子；自动扩张生成的株不重复消耗


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
