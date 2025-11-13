extends Sprite2D

func _ready():
	await get_tree().create_timer(1200).timeout
	visible = true
 
func _process(_delta):
	if !visible:
		return

	if Input.is_action_pressed("remove_watermark"):
		visible = false
		await get_tree().create_timer(1200).timeout
		visible = true
