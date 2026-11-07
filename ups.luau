--!nonstrict

local upsName = noctalia.getConfig("ups_name") or "ups@localhost"
local refreshSeconds = tonumber(noctalia.getConfig("refresh_seconds")) or 5
refreshSeconds = math.clamp(refreshSeconds, 2, 60)

local state = {
	label = "Waiting for UPS",
	charge = "--%",
	glyph = "battery",
	detail = "Waiting for the first NUT response",
}
local requestPending = false

local function render()
	barWidget.setGlyph(state.glyph)
	barWidget.setText(state.charge)
	barWidget.setTooltip({
		{ key = "UPS", value = upsName },
		{ key = "State", value = state.label },
		{ key = "Charge", value = state.charge },
		{ key = "Details", value = state.detail },
	})

	if state.label == "Low battery" or state.label == "Replace battery" or state.label == "Overload" then
		barWidget.setGlyphColor("error")
	elseif state.label == "Charging" then
		barWidget.setGlyphColor("primary")
	else
		barWidget.setGlyphColor("on_surface")
	end
end

local function parse_text_snapshot(output)
	local values = {}
	for line in string.gmatch(output, "[^\r\n]+") do
		local key, value = string.match(line, "^%s*([^:]+):%s*(.-)%s*$")
		if key ~= nil then
			values[key] = value
		end
	end
	return values
end

local function status_view(values)
	local status = string.upper(tostring(values["ups.status"] or ""))
	local tokens = {}
	for token in string.gmatch(status, "%S+") do
		tokens[token] = true
	end

	local charge = tonumber(values["battery.charge"])
	local chargeText = "--%"
	if charge ~= nil then
		charge = math.clamp(charge, 0, 100)
		chargeText = string.format("%.0f%%", charge)
	end

	if tokens.FSD then
		return "Forced shutdown", "alert-triangle", chargeText
	elseif tokens.RB then
		return "Replace battery", "battery-exclamation", chargeText
	elseif tokens.OVER then
		return "Overload", "alert-triangle", chargeText
	elseif tokens.BYPASS then
		return "Bypass", "arrows-left-right", chargeText
	elseif tokens.LB then
		return "Low battery", "battery-exclamation", chargeText
	elseif tokens.OB or tokens.DISCHRG then
		return "Discharging", "battery-4", chargeText
	elseif tokens.CHRG then
		return "Charging", "battery-charging", chargeText
	elseif tokens.OFF then
		return "Off", "battery-off", chargeText
	elseif tokens.TRIM then
		return "Voltage trim", "plug", chargeText
	elseif tokens.BOOST then
		return "Voltage boost", "plug", chargeText
	elseif tokens.CAL then
		return "Self-test", "battery", chargeText
	elseif tokens.OL then
		return "On line", "plug", chargeText
	end
	return "Unknown", "battery", chargeText
end

local function apply_values(values)
	local label, glyph, charge = status_view(values)
	state = {
		label = label,
		charge = charge,
		glyph = glyph,
		detail = values["ups.status"] or "UPS status was not reported",
	}
	render()
end

local function show_unavailable(message)
	state = {
		label = "Unavailable",
		charge = "--%",
		glyph = "battery-off",
		detail = message or "upsc did not return UPS data",
	}
	render()
end

local function read_plain_text()
	local started = noctalia.runAsync({ "upsc", upsName }, function(result)
		requestPending = false
		if result.exitCode ~= 0 then
			show_unavailable(string.sub(result.stderr or "upsc failed", 1, 180))
			return
		end
		local values = parse_text_snapshot(result.stdout or "")
		if values["ups.status"] == nil then
			show_unavailable("upsc returned no ups.status value")
			return
		end
		apply_values(values)
	end)
	if not started then
		requestPending = false
		show_unavailable("Could not start upsc")
	end
end

local function request_snapshot()
	if requestPending then
		return
	end
	requestPending = true
	local started = noctalia.runAsync({ "upsc", "-j", upsName }, function(result)
		if result.exitCode == 0 then
			local ok, values = pcall(function()
				return noctalia.json.decode(result.stdout or "")
			end)
			if ok and type(values) == "table" and values["ups.status"] ~= nil then
				requestPending = false
				apply_values(values)
			else
				read_plain_text()
			end
		else
			read_plain_text()
		end
	end)
	if not started then
		requestPending = false
		show_unavailable("Could not start upsc")
	end
end

noctalia.setUpdateInterval(refreshSeconds * 1000)
render()

function update()
	request_snapshot()
end
