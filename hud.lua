local conky_dir = '/home/bnc/.conky/json/'
package.path = package.path .. ';' .. conky_dir .. '?.lua'

require 'cairo'
require 'bit'
require 'math'
require 'json'
require 'imlib2'
require 'string'

-- Extend tostring to work better on tables
-- make it output in {a,b,c...;x1=y1,x2=y2...} format; use nexti
-- only output the LH part if there is a table.n and members 1..n
--   x: object to convert to string
-- returns
--   s: string representation
local _tostring = tostring
local _print = print

function tostring(x)
  local s
  if type(x) == "table" then
    us = "{"
    local i, v = next(x)
    while i do
      s = s .. tostring(i) .. "=" .. tostring(v)
      i, v = next(x, i)
      if i then s = s .. "," end
    end
    return s .. "}"
  else return _tostring(x)
  end
end

local _cairo_surface = nil
local _cairo = nil
local _width = nil
local _height = nil

function surface()
	if _cairo_surface == nil or
	   _width ~= conky_window.width or
	   _height ~= conky_window.height
	then
		_cairo_surface = cairo_xlib_surface_create(
			conky_window.display,
			conky_window.drawable,
			conky_window.visual,
			conky_window.width,
			conky_window.height
		);

		_width  = conky_window.width
		_height = conky_window.height
	end

	return _cairo_surface;
end

function cairo()
	if _cairo == nil or
	   _width ~= conky_window.width or
	   _height ~= conky_window.height
	then
		_cairo = cairo_create(surface())
	end

	return _cairo
end

function color(rgba)
	return {
		type = "color",
		a = bit.band(bit.rshift(rgba, 24), 0xff) / 255.0,
		r = bit.band(bit.rshift(rgba, 16), 0xff) / 255.0,
		g = bit.band(bit.rshift(rgba, 8), 0xff) / 255.0,
		b = bit.band(rgba, 0xff) / 255.0
	};
end

function set_source(def)
	if def.type == "color" then
		cairo_set_source_rgba(cairo(), def.r, def.g, def.b, def.a)
	elseif def.type == "pattern" then
		cairo_set_source(cairo(), def.pattern)
	end
end

function fill(rect, pattern)
	set_source(pattern)
	cairo_rectangle(cairo(), rect.x, rect.y, rect.width, rect.height)
	cairo_fill(cairo())
end

local _resources = {
	patterns = {}
}

function linear_gradient(p_from, p_to, colors)
	local pattern = cairo_pattern_create_linear(p_from[1], p_from[2], p_to[1], p_to[2])
	
	for stop, col in pairs(colors) do
		cairo_pattern_add_color_stop_rgba(pattern, stop, col.r, col.g, col.b, col.a)
	end

	table.insert(_resources.patterns, pattern)

	return {
		type = "pattern",
		pattern = pattern
	}
end

function radial_gradient(center, inner_radius, outer_radius, colors)
	local pattern = cairo_pattern_create_radial(
		center[1], center[2], inner_radius,
		center[1], center[2], outer_radius
	)
	
	for stop, col in pairs(colors) do
		cairo_pattern_add_color_stop_rgba(pattern, stop, col.r, col.g, col.b, col.a)
	end

	table.insert(_resources.patterns, pattern)

	return {
		type = "pattern",
		pattern = pattern
	}
end

function clear()
	cairo_save(cairo())
	cairo_set_operator(cairo(), CAIRO_OPERATOR_CLEAR)
	cairo_paint(cairo())
	cairo_restore(cairo())
end

function cleanup()
	for idx,pattern in pairs(_resources.patterns) do
		cairo_pattern_destroy(pattern)
	end

	_resources.patterns = {}
end

function rect(x, y, w, h)
	return {
		type = "rect",
		x = x,
		y = y,
		width = w,
		height = h
	}
end

function parse(text)
	if (type(text) == "string") then
		return tonumber(conky_parse(text))
	end

	return text
end

local _text_color = color(0xffffffff)
local _text_font = {family = "Sans", size = 8, bold = false}
local _text_shadow = nil

function text_color(col)
	_text_color = color(col)
end

function text_font(family, size, bold)
	if family ~= nil then _text_font.family = family end
	if size ~= nil then _text_font.size = size end
	if bold ~= nil then _text_font.bold = bold end
end

function text_face(font)
	cairo_select_font_face(
		cairo(),
		font.family,
		CAIRO_FONT_SLANT_NORMAL,
		font.bold and CAIRO_FONT_WEIGHT_BOLD or CAIRO_FONT_WEIGHT_NORMAL
	)
	cairo_set_font_size(cairo(), font.size)
end

function text_impl(x, y, msg, font, col)
	text_face(font)
	set_source(col)

	cairo_move_to(cairo(), x, y)
	cairo_text_path(cairo(), msg)
	cairo_fill(cairo())
end

local CENTER = "center"
local LEFT   = "left"
local RIGHT  = "right"

function text(x, y, msg, alignment)
	if alignment == nil then alignment = LEFT end
	
	msg = conky_parse(msg)
	
	local text_ext = cairo_text_extents_t:create()
	text_face(_text_font)
	cairo_text_extents(cairo(), msg, text_ext)
	if alignment == CENTER then
		x = x - text_ext.x_advance / 2
	elseif alignment == RIGHT then
		x = x - text_ext.x_advance
	end
	
	if _text_shadow then
		text_impl(
			x + _text_shadow.offset_x,
			y + _text_shadow.offset_y,
			msg,
			_text_font,
			_text_shadow.color
		)
	end

	text_impl(x, y, msg, _text_font, _text_color)
end

function text_shadow(offset_x, offset_y, col)
	if offset_x == nil and offset_y == nil and col == nil then
		_text_shadow = nil
	else
		_text_shadow = {
			offset_x = offset_x or 1,
			offset_y = offset_y or 1,
			color = col or color(0xff000000)
		}
	end
end

function draw_bar(pos, def, value)
	local val = conky_parse(value)
	local percentage = (val - def.limits[1]) / (def.limits[2] - def.limits[1]);
	local bar_bg = rect(pos[1], pos[2], def.width, def.height)
	local bar = rect(pos[1], pos[2], def.width * percentage, def.height)

	if def.background then
		fill(bar_bg, def.background)
	end

	fill(bar, def.foreground)
end

function define_bar(fg_fill, bg_fill, dimensions, limits)
	return {
		background = bg_fill,
		foreground = fg_fill,
		width      = dimensions[1] or 100,
		height     = dimensions[2] or 5,
		limits     = limits or {0, 100}
	}
end

local _graph_data = {}

function draw_chart(name, pos, def, value)
	if _graph_data[name] == nil then
		_graph_data[name] = {}
	end

	local data = _graph_data[name]
	table.insert(data, conky_parse(value))

	while table.getn(data) > def.width do
		table.remove(data, 1)
	end

	if def.background then
		fill(rect(pos[1], pos[2], def.width, def.height), def.background)
	end

	local percentage
	local dlen = table.getn(data)
	for x = 1, dlen do
		percentage = (data[x] - def.limits[1]) / (def.limits[2] - def.limits[1])
		fill(
			rect(
				pos[1] + def.width - dlen + x - 1, 
				pos[2] + def.height * (1 - percentage), 
				1, 
				def.height * percentage
			),
			def.foreground
		)
	end
end

function define_chart(fg_fill, bg_fill, dimensions, limits)
	return {
		background = bg_fill,
		foreground = fg_fill,
		width      = dimensions[1] or 100,
		height     = dimensions[2] or 20,
		limits     = limits or {0, 100}
	}
end

function define_ring(fg_fill, bg_fill, innerRadius, outerRadius, startAngle, endAngle, negative)
	return {
		background  = bg_fill,
		foreground  = fg_fill,
		innerRadius = innerRadius,
		outerRadius = outerRadius,
		startAngle  = startAngle,
		endAngle    = endAngle,
		negative    = negative or false
	}
end

function draw_ring(pos, def, value)
	local avg_rad = (def.innerRadius + def.outerRadius) / 2
	local arc_fn = def.negative and cairo_arc_negative or cairo_arc
	
	cairo_set_line_width(cairo(), def.outerRadius - def.innerRadius)

	if def.background then
		set_source(def.background)
		arc_fn(cairo(), pos[1], pos[2], avg_rad, def.startAngle, def.endAngle)
		cairo_stroke(cairo())
	end

	local val = parse(value)/100
	local endAngle = def.startAngle + (def.endAngle - def.startAngle) * val

	if val > 0 then

		set_source(def.foreground)
		arc_fn(cairo(), pos[1], pos[2], avg_rad, def.startAngle, endAngle)
		cairo_stroke(cairo())
	end
end

function define_ring_chart(fg_fill, bg_fill, inner_radius, outer_radius, start_angle, end_angle, negative, max)
	return {
		foreground  = fg_fill,
		background  = bg_fill,
		innerRadius = inner_radius,
		outerRadius = outer_radius,
		startAngle  = start_angle,
		endAngle    = end_angle,
		negative    = negative or false,
		max         = max or 120
	}
end

function draw_ring_chart(name, pos, def, value)
	if _graph_data[name] == nil then
		_graph_data[name] = {}
	end

	local data = _graph_data[name]
	local val = parse(value)
	local radius, line_width, start_angle, end_angle, angle_step, data_len

	table.insert(data, val)
	
	while table.getn(data) > def.max do
		table.remove(data, 1)
	end

	if def.background then
		line_width = def.outerRadius - def.innerRadius
		radius = (def.outerRadius + def.innerRadius) / 2

		set_source(def.background)
		cairo_set_line_width(cairo(), line_width)
		cairo_arc(cairo(), pos[1], pos[2], radius, def.startAngle, def.endAngle)
		cairo_stroke(cairo())
	end

	data_len = table.getn(data)
	angle_step = math.abs(def.endAngle - def.startAngle) / def.max

	set_source(def.foreground)

	for x = 1, data_len do
		line_width = (def.outerRadius - def.innerRadius) * data[x] / 100
		radius = def.innerRadius + line_width / 2

		if def.negative then
			start_angle = def.endAngle - angle_step * (data_len - x + 1)
		else
			start_angle = def.startAngle + angle_step * (data_len - x)
		end

		end_angle = start_angle + angle_step 

		cairo_set_line_width(cairo(), line_width)
		cairo_arc(cairo(), pos[1], pos[2], radius, start_angle, end_angle)
		cairo_stroke(cairo())
	end
end

function url_encode(str)
	if (str) then
		str = string.gsub (str, "\n", "\r\n")
		str = string.gsub (str, "([^%w %-%_%.%~])",
			function (c) return string.format ("%%%02X", string.byte(c)) end)
		str = string.gsub (str, " ", "+")
	end
	return str	
end

function yql(query)
	local esc_q = url_encode(query)
	local req = "http://query.yahooapis.com/v1/public/yql?q=" .. esc_q .. "&format=json"
	local result = conky_parse("${execi 120 wget -q -O- \"" .. req .. "\"}")

	if string.len(result) == 0 then return nil end

	return json.decode(result)
end

function get_day_name(offset)
	return os.date("%A", os.time() + 86400 * offset)
end

function get_forecast_text(data, day)
	local celsius = "°C"
	local day_name

	day_name = get_day_name(day-1)

	return day_name .. ", " ..
	       data[day].text .. ", " ..
	       data[day].low .. celsius .. " / " .. 
	       data[day].high .. celsius
end

local _weather_icons = {}

function display_weather_icon(pos, icon_size, code)
	if _weather_icons[code] == nil then
		img_path = "/home/bnc/.conky/icons/weather_" .. code .. ".png"
		_weather_icons[code] = imlib_load_image(img_path)
	end

	image = _weather_icons[code]
	imlib_context_set_image(image)
	image_w, image_h = imlib_image_get_width(), imlib_image_get_height()

	buffer = imlib_create_cropped_scaled_image(0, 0, image_w, image_h, icon_size, icon_size)
	imlib_context_set_image(buffer)
	imlib_render_image_on_drawable(pos[1], pos[2])
	imlib_free_image()
end

local _weather_cache
local _weather_last_query = 0

function get_weather()
	local current_time = os.time()

	if _weather_cache and current_time - _weather_last_query < 600 then
		return _weather_cache
	end

	local location = yql("SELECT * FROM geo.places WHERE text = \"Budapest\"")

	if location and location.query.count > 0 then
		local place = location.query.results.place[1]
		local results = yql("SELECT * FROM weather.forecast WHERE u = \"c\" AND woeid = " .. place.woeid)

		if results then
			_weather_last_query = os.time()
			_weather_cache = results
		
			return results
		end
	end

	return nil
end

function is_leap_year(year)
	return year % 4 == 0 and year % 400 ~= 0
end

function get_month_length(year, month)
	local lengths = { 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 }

	if month == 2 and is_leap_year(year) then
		return 29
	end

	return lengths[month]
end

function get_day_of(year, month, day)
	local days = 0

	for _year = 1900, year-1 do
		days = days + (is_leap_year(_year) and 366 or 365)
	end

	for _month = 1, month-1 do
		days = days + get_month_length(year, _month)
	end

	return (days + day - 1) % 7 + 1
end

function display_calendar(pos)
	local dist = {x = 25, y = 20}
	local pos_x = pos[1]
	local pos_y = pos[2]
	local day_names = { 'Mo', 'Tu', 'We', 'Th', 'Fr', 'Sa', 'Su' }
	local year, month, day
	local first_day, month_length
	local white = 0xffffffff
	local yellow = 0xffffff00
	local red = 0xffff0000

	year, month, day = tonumber(os.date('%Y')), tonumber(os.date('%m')), tonumber(os.date('%d'))
	month_length = get_month_length(year, month)
	first_day = get_day_of(year, month, 1)
	last_day = get_day_of(year, month, month_length)

	text_font("Josefin Sans Std", 18, true)
	text_color(white)
	text(pos_x + dist.x * 3, pos_y, os.date("%B %Y"), CENTER)
	text_font(nil, 12, true)
	
	for i = 1, 7 do
		text_color(white)
		text(pos_x + dist.x * (i-1), pos_y + dist.y, day_names[i], CENTER)

		for j = 1, 6 do
			local current_day = (j-1) * 7 + (i-1) - first_day + 2
			
			if current_day > 0 and current_day <= month_length then
				text_color(current_day == day and yellow or (i == 7 and red or white))
				text(pos_x + dist.x * (i-1), pos_y + dist.y * (j + 1), tostring(current_day), CENTER)
			end
		end
	end
end

local PI = 3.141592654
local bar_stops = {[0] = color(0x3fffffff), [0.60] = color(0x7fffff00), [1] = color(0xffff0000)}

local last_draw = 0

function conky_main()
	if conky_window == nil or conky_parse("${cpu cpu0}") == nil then return end

	local current_time = os.time()
	if current_time - last_draw < 1 then return end
	last_draw = current_time

	cairo() -- init cairo firs
	--clear()

	fill(rect(0,0,_width,_height), linear_gradient(
		{0, 0},
		{0, _height},
		{[0] = color(0x66222222), [1] = color(0xcc000000)}
	));
	
	local stops = { 
		[0.0] = color(0x1fffffff),
		[0.5] = color(0x7fffffff),
		[1.0] = color(0x1fffffff)
	}

	fill(rect(0,0,_width,3), linear_gradient({0, 0}, {_width, 0}, stops))
	fill(rect(0,_height-3,_width,3), linear_gradient({0, 0}, {_width, 0}, stops))
	text_color(0xaaffffff)

	text_font("Pinyon Script", 45, false)
	text_shadow(2, 2)
	text(683, 40, "${time %H:%M}", CENTER);
	text_font("Pinyon Script", 16, true)
	text(683, 65, "${time %A, %d %B, %Y}", CENTER)
	text_font(nil, nil, false)

--	text_font("Josefin Sans Std", 20)
--	text_color(0xffffffff)
--	text_shadow(2, 2)
--
--	text(140, 60, "CPU")
--	text_font("Unispace", 12)
--	text(35, 85, "0 ${cpu cpu0}%")
--	text(35, 115, "1 ${cpu cpu1}%")
--	text(35, 145, "2 ${cpu cpu2}%")
--	text(35, 175, "3 ${cpu cpu3}%")

	local bar_look = define_bar(linear_gradient({80, 0}, {230, 0}, bar_stops), color(0x3f000000), {150, 4})

--	draw_bar({80, 80}, bar_look, "${cpu cpu0}")
--	draw_bar({80, 110}, bar_look, "${cpu cpu2}")
--	draw_bar({80, 140}, bar_look, "${cpu cpu3}")
--	draw_bar({80, 170}, bar_look, "${cpu cpu4}")
--
--	text_font("Josefin Sans Std", 20)
--	text(360, 60, "Memory")
--	text_font("Unispace", 12)
--	text(260, 85,  "mem" ); text(290, 85,  "$memperc%")
--	text(260, 115, "swap"); text(290, 115, "$swapperc%")
--
--	local bar_look = define_bar(linear_gradient({300, 0}, {450, 0}, bar_stops), color(0x3f000000), {150, 4})
--
--	draw_bar({325, 80}, bar_look, "$memperc")
--	draw_bar({325, 110}, bar_look, "$swapperc")
--
--	local graph_look = define_graph(linear_gradient({0, 180}, {0, 130}, bar_stops), color(0x3f000000), {215, 50})
--
--	draw_graph("mem graph", {260, 130}, graph_look, "$memperc")

	local dist   = 1
	local pos    = {x = 1366/2, y = 140}
	local radius = {inner = 45, outer = 55}
	draw_ring({pos.x + dist, pos.y - dist}, define_ring(linear_gradient({pos.x, pos.y-radius.outer}, {pos.x+radius.outer, pos.y}, bar_stops), color(0x3f000000), radius.inner, radius.outer, PI*1.5, PI*2), "${cpu cpu0}")
	draw_ring({pos.x + dist, pos.y + dist}, define_ring(linear_gradient({pos.x+radius.outer, pos.y}, {pos.x, pos.y+radius.outer}, bar_stops), color(0x3f000000), radius.inner, radius.outer, 0, PI/2     ), "${cpu cpu1}")
	draw_ring({pos.x - dist, pos.y + dist}, define_ring(linear_gradient({pos.x, pos.y+radius.outer}, {pos.x-radius.outer, pos.y}, bar_stops), color(0x3f000000), radius.inner, radius.outer, PI/2, PI    ), "${cpu cpu2}")
	draw_ring({pos.x - dist, pos.y - dist}, define_ring(linear_gradient({pos.x-radius.outer, pos.y}, {pos.x, pos.y-radius.outer}, bar_stops), color(0x3f000000), radius.inner, radius.outer, PI, PI*1.5  ), "${cpu cpu3}")
	
	local temp_gradient_down = linear_gradient({pos.x,pos.y-38}, {pos.x, pos.y+38}, bar_stops)
	local temp_gradient_up   = linear_gradient({pos.x,pos.y+38}, {pos.x, pos.y-38}, bar_stops)
	local temp1 = parse("${execi 5 sensors | grep 'Core 0' | awk '{print $3}' | tr -d +°C}")
	local temp2 = parse("${execi 5 sensors | grep 'Core 1' | awk '{print $3}' | tr -d +°C}")
	draw_ring({pos.x + dist, pos.y}, define_ring(temp_gradient_down, color(0x3f000000), 33, 43, -PI/2, PI/2), temp1)
	draw_ring({pos.x - dist, pos.y}, define_ring(temp_gradient_up,   color(0x3f000000), 33, 43, PI/2, PI*1.5), temp2)

	text_font("Unispace", 12)
	text(pos.x + 5, pos.y + 4, temp1 .. "°C")
	text(pos.x - 5, pos.y + 4, temp2 .. "°C", RIGHT)
	--text(pos.x + radius.inner, pos.y - radius.inner,     "${cpu cpu0}%")
	--text(pos.x + radius.inner, pos.y + radius.inner + 8, "${cpu cpu1}%")
	--text(pos.x - radius.inner, pos.y + radius.inner + 8, "${cpu cpu2}%", RIGHT)
	--text(pos.x - radius.inner, pos.y - radius.inner,     "${cpu cpu3}%", RIGHT)
	text_font("Josefin Sans Std", 18, true)
	text(pos.x, pos.y + 25, "CPU", CENTER)

--	local mem_chart = define_chart(color(0xffffffff), color(0x3f000000), {150, 50})
--	draw_chart("mem graph", {1366/2-220, 140}, mem_chart, "$memperc")
--	draw_chart("cpu graph", {1366/2+80, 140}, mem_chart, "$cpu")

	local radial_grad = radial_gradient({pos.x, pos.y}, 60, 85, bar_stops)

	local mem_rad_chart = define_ring_chart(radial_grad, color(0x3f000000), 60, 85, -PI/4, PI/4)
	draw_ring_chart("mem rad chart", {pos.x, pos.y}, mem_rad_chart, "$memperc")

	local cpu_rad_chart = define_ring_chart(radial_grad, color(0x3f000000), 60, 85, PI - PI/4, PI + PI/4, true)
	draw_ring_chart("cpu rad chart", {pos.x, pos.y}, cpu_rad_chart, "$cpu")

	--print(parse("${fs_used_perc /home}"))
	local homedir_gradient = linear_gradient({pos.x, pos.y+63}, {pos.x, pos.y-63}, bar_stops)
	local battery_gradient = linear_gradient({pos.x, pos.y-63}, {pos.x, pos.y+63}, bar_stops)
	draw_ring({pos.x, pos.y}, define_ring(homedir_gradient, color(0x3f000000), 87, 90, PI/4,    -PI/4, true ), "${fs_used_perc /home}")
	draw_ring({pos.x, pos.y}, define_ring(battery_gradient, color(0x3f000000), 87, 90, 3*PI/4, 5*PI/4, false), "${battery_percent BAT0}")


	local pos = {x = 450, y = 80}
	text_font("Josefine Sans Std", 18, false)
	text(pos.x, pos.y, "Top")

	text_font("Unispace", 12)
	text(pos.x, pos.y + 20,  "${top name 1}"); text(pos.x + 130, pos.y +  20, "${top cpu 1}%", RIGHT)
	text(pos.x, pos.y + 40,  "${top name 2}"); text(pos.x + 130, pos.y +  40, "${top cpu 2}%", RIGHT)
	text(pos.x, pos.y + 60,  "${top name 3}"); text(pos.x + 130, pos.y +  60, "${top cpu 3}%", RIGHT)
	text(pos.x, pos.y + 80,  "${top name 4}"); text(pos.x + 130, pos.y +  80, "${top cpu 4}%", RIGHT)
	text(pos.x, pos.y + 100, "${top name 5}"); text(pos.x + 130, pos.y + 100, "${top cpu 5}%", RIGHT)

	pos = {x = 785, y = 80}
	text_font("Josefine Sans Std", 18, false)
	text(pos.x + 130, pos.y, "IO Top", RIGHT)

	text_font("Unispace", 12)
	text(pos.x, pos.y +  20, "${top_io name 1}"); text(pos.x + 130, pos.y +  20, "${top io_perc 1}%", RIGHT)
	text(pos.x, pos.y +  40, "${top_io name 2}"); text(pos.x + 130, pos.y +  40, "${top io_perc 2}%", RIGHT)
	text(pos.x, pos.y +  60, "${top_io name 3}"); text(pos.x + 130, pos.y +  60, "${top io_perc 3}%", RIGHT)
	text(pos.x, pos.y +  80, "${top_io name 4}"); text(pos.x + 130, pos.y +  80, "${top io_perc 4}%", RIGHT)
	text(pos.x, pos.y + 100, "${top_io name 5}"); text(pos.x + 130, pos.y + 100, "${top io_perc 5}%", RIGHT)

	pos = {x=940, y=45}
	local results = get_weather()

	if results then
		local channel = results.query.results.channel
		--print(results.query.results.channel.wind)
		--print(results.query.results.channel.astronomy)
		--print(results.query.results.channel.item.condition)
		--print(results.query.results.channel.item.forecast)

		display_weather_icon({pos.x, pos.y}, 48, channel.item.condition.code)
		display_weather_icon({pos.x + 12, pos.y + 50 }, 24, channel.item.forecast[2].code)
		display_weather_icon({pos.x + 12, pos.y + 82 }, 24, channel.item.forecast[3].code)
		display_weather_icon({pos.x + 12, pos.y + 114}, 24, channel.item.forecast[4].code)

		local celsius = "°C"
		text_font("Josefin Sans Std", 14, true)
		text(pos.x + 50, pos.y + 32, channel.item.condition.text .. ", " ..
		     channel.item.condition.temp .. celsius .. " (" .. channel.item.forecast[1].text .. ", " ..
			 channel.item.forecast[1].low .. celsius .. " / " ..
			 channel.item.forecast[1].high .. celsius .. ")")

		text_font(nil, 12)
		text(pos.x + 40, pos.y + 66,  get_forecast_text(channel.item.forecast, 2))
		text(pos.x + 40, pos.y + 98,  get_forecast_text(channel.item.forecast, 3))
		text(pos.x + 40, pos.y + 130, get_forecast_text(channel.item.forecast, 4))
	else
		text_font("Josefin Sans Std", 15, true)
		text(pos.x, pos.y + 90, "No weather data available")
	end

	display_calendar({250, 60})

	cleanup()
end

