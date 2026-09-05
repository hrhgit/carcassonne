class_name ThreeLandRiverTile
extends TileArtwork

# The two authored fields are independent gameplay surfaces. Placement code
# only knows the prefab's edge markers; irrigation or crop systems can address
# a field without regenerating any of this scene's art.
func sow_field(field_id: StringName) -> bool:
	var field := _field_with_id(field_id)
	if field == null:
		return false
	field.sow()
	return true


func wilt_field(field_id: StringName) -> bool:
	var field := _field_with_id(field_id)
	if field == null:
		return false
	field.wilt()
	return true


func restore_field_to_bare_soil(field_id: StringName) -> bool:
	var field := _field_with_id(field_id)
	if field == null:
		return false
	field.restore_bare_soil()
	return true


func _field_with_id(field_id: StringName) -> FieldGrowthState:
	for child in get_children():
		if child is FieldGrowthState and child.field_id == field_id:
			return child
	return null
