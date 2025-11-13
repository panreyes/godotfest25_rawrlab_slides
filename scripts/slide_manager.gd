extends Node2D
class_name SlideDeckPresenter

var deck_text: String = ""

var content_path = "res://content/content.txt"

@onready var title_label: Label = $"../SlideContainer/Slide/TitleLabel"
@onready var content_label: RichTextLabel = $"../SlideContainer/Slide/ContentLabel"
@onready var overlay := %Overlay
@onready var slide := $"../SlideContainer/Slide"
@onready var slide_container := $"../SlideContainer"
@onready var image := $"../SlideContainer/Slide/Image"

@export var min_font_size := 8
@export var max_font_size := 60

var _image_tex
var _current_slide_template_name = ""
var _current_image_name = ""
var _previous_slide_template_name
var _previous_title
var _last_mtime
var _check_countdown = 3.0
var _going_back := false

var _image_desired_width
var _image_desired_height

# Internal data structures
var _slides: Array = []       # [ {title:String, bullets:[{text:String, level:int}]} , ... ]
var _slide_i: int = 0         # current slide index
var _reveal_i: int = 0        # number of bullets currently revealed on this slide

func _ready() -> void:
	_check_for_content_changes()
	_slide_i = 0
	_reveal_i = 0
	_render()

func _input(event: InputEvent) -> void:
	if event is InputEventKey \
	and event.pressed and not event.echo \
	and event.alt_pressed \
	and (event.keycode == KEY_ENTER or event.keycode == KEY_KP_ENTER):
		var w := get_window()
		if w.mode == Window.MODE_EXCLUSIVE_FULLSCREEN or w.mode == Window.MODE_FULLSCREEN:
			w.mode = Window.MODE_WINDOWED
		else:
			w.mode = Window.MODE_EXCLUSIVE_FULLSCREEN  # or MODE_FULLSCREEN for borderless

	if Input.is_key_pressed(KEY_ESCAPE):
		get_tree().quit()

	if Input.is_key_pressed(KEY_R):
		_load_content()
		_render()
	
	if overlay.visible:
		return

	if Input.is_key_pressed(KEY_DOWN):
		go_to_slide(_slide_i + 1)
	elif Input.is_key_pressed(KEY_UP):
		go_to_slide(_slide_i - 1)

	if event.is_action_pressed("ui_right"):
		_step_forward()
	elif event.is_action_pressed("ui_left"):
		_step_back()

	get_viewport().set_input_as_handled()

func _load_content():
	deck_text = FileAccess.get_file_as_string(content_path)
	_slides = _parse_deck(deck_text)

func _step_forward() -> void:
	if _slides.is_empty():
		return
	_going_back = false
	var bullets = _slides[_slide_i].bullets
	if _reveal_i < bullets.size():
		_reveal_i += 1                       # reveal next bullet
	else:
		# move to next slide (if any), start unrevealed
		if _slide_i < _slides.size() - 1:
			_slide_out_effect()
			_slide_i += 1
			_reveal_i = 0
			image.visible = false
			_current_image_name = ""
	_render()

func _slide_out_effect():
	if title_label.text == "" or title_label.text == _previous_title:
		return

	var img = get_viewport().get_texture().get_image()
	var target := Vector2i(1280, 720)

	if img.get_size() != target:
		img.resize(target.x, target.y, Image.INTERPOLATE_LANCZOS)

	overlay.texture = ImageTexture.create_from_image(img)
	overlay.visible = true

	var t := create_tween().set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_IN)
	t.tween_property(overlay, "position:x", -1280, 0.5)
	await t.finished
	overlay.visible = false
	overlay.position.x = 0

func _step_back() -> void:
	if _slides.is_empty():
		return
	_going_back = true
	if _reveal_i > 0:
		_reveal_i -= 1
	else:
		# go to previous slide, fully revealed
		if _slide_i > 0:
			_slide_i -= 1
			_reveal_i = _slides[_slide_i].bullets.size()
			#_reveal_i = 0
	_render()

# -- Rendering ----------------------------------------------------------------

func _render() -> void:
	if _slides.is_empty():
		title_label.text = ""
		content_label.text = ""
		_current_image_name = ""
		image.visible = false
		return

	var _slide = _slides[_slide_i]
	if _slide.title != title_label.text:
		_previous_title = title_label.text
		title_label.text = _slide.title
		_resize_title()

	var shown := ""
	var count = min(_reveal_i, _slide.bullets.size())
	
	# Just triggered
	#if _reveal_i == 0:
	# We check if we changed the image, so it should be OK to just do this on every render
	_load_slide_template(_slide.template)
	_load_slide_image(_slide.image)
	
	for i in count:
		var b = _slide.bullets[i]
		if b.level == -1: # Command!
			if _reveal_i - 1 == i:
				_process_command(b.text)
				if(_going_back):
					_step_back()
				else:
					_step_forward()
				return
			continue
		
		for j in b.level:
			shown += " "

		if b.text != "" and b.level == 2:
			shown += "• "

		if b.level > 2:
			shown += "[color=#95ff8d]" + b.text + "[/color]\n"
		else:
			shown += b.text + "\n"

	content_label.text = shown

func _parse_deck(text: String) -> Array:
	var slides: Array = []
	var current := { "title": "", "bullets": [] }
	var last_template_name = "base"
	text = text.replace("\t","   ")

	for raw_line in text.split("\n"):
		var line := raw_line.rstrip(" ")              # keep leading spaces, trim trailing
		if line.strip_edges() == "":
			if current.bullets.back() != null:
				current.bullets.back().text += "\n"
			continue

		# Count leading spaces
		var trimmed_lead := line.lstrip(" ")
		var lead_spaces := line.length() - trimmed_lead.length()

		if trimmed_lead.begins_with("- "):
			# Top-level slide title (no leading spaces)
			if lead_spaces == 0:
				# commit previous slide (if it has a title)
				if current.title != "" or current.bullets.size() > 0:
					slides.append(current)
				current = { 
					"title": trimmed_lead.substr(2),
					"bullets": [],
					"image": null,
					"template": last_template_name
					}
			else:
				# Bullet: level = (leading spaces - 1), min 0
				var level = max(0, lead_spaces - 1)
				var text_part := trimmed_lead.substr(2)
				current.bullets.append({ "text": text_part, "level": level })
		else:
			# Commands:
			if trimmed_lead.find("="):
				var cmd = trimmed_lead.split("=")
				match(cmd[0]):
					"image":
						if !current.image:
							current.image = cmd[1]
						current.bullets.append({ "text": trimmed_lead, "level": -1 })
					"slide":
						current.template = cmd[1]
						last_template_name = cmd[1]

	# Append the last slide if any content
	if current.title != "" or current.bullets.size() > 0:
		slides.append(current)

	#print(slides)

	return slides

func _process(delta):
	_check_countdown -= delta
	if _check_countdown <= 0:
		_check_for_content_changes()
		_check_countdown = 3.0

func _check_for_content_changes():
	var _mtime = FileAccess.get_modified_time(content_path)
	if _mtime != _last_mtime:
		print("content changed")
		_last_mtime = _mtime
		_load_content()
		

# Jump to a specific slide (0-based). Reveals nothing initially.
func go_to_slide(index: int) -> void:
	if index < 0 or index >= _slides.size():
		return
	_slide_i = index
	_reveal_i = 0
	_render()

func _resize_title() -> void:
	# Binary search the largest font size that still fits.
	var low := min_font_size
	var high := max_font_size
	var best := low

	# Guard: empty or zero-size label
	if title_label.size.x <= 0.0 or title_label.size.y <= 0.0:
		return

	while low <= high:
		var mid := int(floor((low + high) * 0.5))
		title_label.add_theme_font_size_override("font_size", mid)

		# get_minimum_size() reflects current text, wrapping and theme font size.
		var ms := title_label.get_minimum_size()

		# It fits if both dimensions fit inside our current rect.
		if ms.x <= title_label.size.x and ms.y <= title_label.size.y:
			best = mid
			low = mid + 1
		else:
			high = mid - 1

	title_label.add_theme_font_size_override("font_size", best)

func _process_command(text):
	var cmd = text.split("=")
	match(cmd[0]):
		"image":
			_slides[_slide_i].image = cmd[1]
			_load_slide_image(_slides[_slide_i].image)
		"slide":
			_load_slide_template(cmd[1])

func _load_slide_image(image_name):
	if image_name == null:
		return

	var path = "res://content/" + image_name
	if !image_name or !ResourceLoader.exists(path):
		print("Image unavailable! " + path)
		image.visible = false
		return

	if _current_image_name == image_name:
		return

	_current_image_name = image_name

	print("Loading image " + path)
	_image_tex = load("res://content/" + image_name) as Texture2D
	image.texture = _image_tex

	var original_width  = image.texture.get_width()
	var original_height = image.texture.get_height()

	var target_w = float(_image_desired_width)
	var target_h = float(_image_desired_height)

	var scale_contain = min(target_w / original_width, target_h / original_height)
	image.scale = Vector2(scale_contain, scale_contain)

	image.visible = true
 
func _load_slide_template(template):
	if template == _current_slide_template_name:
		return

	print("Changing slide to " + template)
	slide.visible = false
	slide.name = "OldSlide"
	slide.queue_free()

	_previous_slide_template_name = _current_slide_template_name
	_current_slide_template_name = template

	var new_slide = load("res://slide_templates/" + template + ".tscn").instantiate()
	new_slide.name = "Slide"
	slide_container.add_child(new_slide)

	title_label = $"../SlideContainer/Slide/TitleLabel"
	content_label = $"../SlideContainer/Slide/ContentLabel"
	image = $"../SlideContainer/Slide/Image"
	slide = $"../SlideContainer/Slide"

	title_label.text = _slides[_slide_i].title
	content_label.text = ""
	_current_image_name = ""
	
	if image.texture:
		_image_desired_width = image.texture.get_width()
		_image_desired_height = image.texture.get_height()
	else:
		_image_desired_width = 300
		_image_desired_height = 300

	_resize_title()
