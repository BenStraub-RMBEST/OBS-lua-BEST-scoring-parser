-- Requires "luajit-request" to be copied into OBS's lua path:
--   Download source from here:
--      https://github.com/LPGhatguy/luajit-request
--   Paste the "luajit-request" folder into here:
--      (you may need to create the "lua" folder below first)
--      C:\Program Files\obs-studio\bin\64bit\lua
--
-- Also requires "htmlparser" to be copied into OBS's lua path:
--   Download source from here:
--      https://github.com/msva/lua-htmlparser
--   Paste the "htmlparser.lua" file and "htmlparser" folder from "src" into here:
--      C:\Program Files\obs-studio\bin\64bit\lua
request = require("luajit-request")
htmlparser = require("htmlparser")

obs           = obslua
timer_source_name = ""
base_addr = ""
num_fields = 1
manual_timer = false
manual_cur_seconds = 0

global_props = nil
p_net_status = nil

between_matches = false
upcoming_matches = {}
switchover_scheduled = false
quick_retry_count = 0

cur_settings = nil
cur_match_phase = ""
cur_match_num = 0

last_text_timer = ""
last_test_field = {}

active_connection_timer_callback = false
active_parsing_update_timer_callback = false


manual_timer_reset_hotkey_id = obs.OBS_INVALID_HOTKEY_ID

RETRY_TIME = 5000
UPDATE_TIME = 200
SWITCH_TO_UPCOMING_TIME = 60000
QUICK_RETRY_MAX_COUNT = 2
TIMER_RESET_SECONDS = 3*60

-- Helper function for un-escaping HTML codes. I'll just update this function with the characters I happen to run into
function unescape_html(str)
	str = string.gsub(str, "&#x2013;", "–") -- en dash
	return str
end

-- Helper function for setting the net status
--   info_type should be obs.OBS_TEXT_INFO_ERROR, obs.OBS_TEXT_INFO_WARNING, or obs.OBS_TEXT_INFO_NORMAL
function set_net_status(str, info_type)
	obs.obs_property_text_set_info_type(p_net_status, info_type)
	obs.obs_data_set_string(cur_settings, "net_status", str)
	obs.obs_properties_apply_settings(global_props, cur_settings)
end

-- Timer for trying to connect (for initial connection or reconnection)
function connection_timer_callback()
	-- make sure base_addr isn't blank
	if base_addr ~= "" then
		-- attempt to query the /Marquee/Match page
		local addr = base_addr .. "/Marquee/Match"
		--print("  Connecting to " .. addr)
		local response = request.send(base_addr .. "/Marquee/Match")
		--print(response)
		if (response) then
			--print(response.code)
			print(response.body)
			if response.code ~= 200 then
				print("Connection failed with response code " .. response.code)
			else
				print("Connection successful.")
				-- stop retrying the connection
				obs.remove_current_callback() -- remove this timer
				active_connection_timer_callback = false
				-- start the periodic updating
				obs.timer_add(parsing_update_timer_callback, UPDATE_TIME)
				active_parsing_update_timer_callback = true
				-- Update the status indicator in the properties
				set_net_status("Connection successful.", obs.OBS_TEXT_INFO_NORMAL)
			end
		else
			print("Connection request failed.")
		end
	end
end

-- Timer callback function for periodically requesting the match info and parsing it
function parsing_update_timer_callback()
	-- First, request the match page:
	-- We shouldn't need to check for blank / invalid base_addr at this point, since this timer
	--  should only be running if we had a successful test connection.
	local addr = base_addr .. "/Marquee/Match"
	local response = request.send(addr)
	
	--print("In parsing_update_timer_callback")
	-- Check for bad response
	if (not response) or (response.code ~= 200) then
		print("Bad response, retrying.")
		quick_retry_count = quick_retry_count + 1
		if quick_retry_count >= QUICK_RETRY_MAX_COUNT then
			print("Too many retries")
			-- if we've retried enough, go back to the slower retry timer
			obs.remove_current_callback() -- remove this timer
			active_parsing_update_timer_callback = false
			obs.timer_add(connection_timer_callback, RETRY_TIME)
			active_connection_timer_callback = true
			-- Update the status indicator in the properties
			set_net_status("Connection lost. Retrying...", obs.OBS_TEXT_INFO_ERROR)
		elseif quick_retry_count == 1 then -- first retry:
			-- Update the status indicator in the properties
			set_net_status("Connection lost. Retrying...", obs.OBS_TEXT_INFO_WARNING)
		end
		-- either way (quick or not), return, since we don't have anything to parse
		return
	end
	if quick_retry_count ~= 0 then
		print("Connection restored.")
		quick_retry_count = 0
		-- Update the status indicator in the properties
		set_net_status("Connection successful.", obs.OBS_TEXT_INFO_NORMAL)
	end
	
	---- start parsing
	local root_parse = htmlparser.parse(response.body)
	
	local need_to_handle_between_matches = false
	
	-- check if root response is blank (in between matches)
	if next(root_parse.nodes) == nil then
		need_to_handle_between_matches = true
		-- actual handling comes later, still need to check for 00:00 indicator
	else
		-- root isn't blank, so go ahead and check the timer
		-- If timer is 00:00, that's the other possible indicator that we're between matches
		
		-- get timer
		local elem_timer = root_parse:select(".nameAndTimer > h2")
		if next(elem_timer) == nil then
			return
		end
		cur_web_time = elem_timer[1]:getcontent()
		--print("==== Current timer is: ".. cur_web_time)
		
		if (cur_web_time == "00:00") or (cur_web_time == "0:00") then
			need_to_handle_between_matches = true
			-- For the first time (when we're just now becoming between matches)
			--  make sure it shows the new "00:00" and doesn't get stuck on "00:01"
			-- After the first time, between_matches will be true, and the upcoming switchover
			--  logic will take over setting the timer label at the appropriate time.
			if not between_matches then
				set_timer_label(cur_web_time, cur_settings)
			end
		else
			need_to_handle_between_matches = false
			-- not between matches, timer text label will get set later along with match num and quads
		end
	end
	
	
	-- If we're between matches, handle that.
	-- This if-then block returns, so no other parsing happens if need_to_handle_between_matches == true.
	if need_to_handle_between_matches then
		-- no nodes means that the match page is blank, so it's in between matches
		-- See if we're just now going to be in between matches:
		if (between_matches == false) then
			between_matches = true
			-- grab the upcoming match table
			upcoming_matches = parse_upcoming_matches_table()
			local switchover_time = obs.obs_data_get_double(cur_settings, "upcoming_time")
			-- if cur_match_num is 0, then switch immediately, since there's not
			--      really an existing match up at that point
			if (cur_match_num == nil or cur_match_num == 0) then
				--print("cur_match_num is " .. tostring(cur_match_num) .. ", siwtching immediately.")
				upcoming_match_switchover()
			-- else, check for auto_switchover to see if we need to auto switch between matches
			elseif (auto_switchover) then
				local effective_switchover_time = switchover_time
				if effective_switchover_time == nil then
					effective_switchover_time = 0
				end
				if manual_timer then
					-- if using the manual timer, then check if there's still time left
					--  and compensate by adding it to the switchover_time
					effective_switchover_time = effective_switchover_time + cur_manual_timer_seconds
				end
				
				-- if there's it's 0 seconds, switch immediately
				if effective_switchover_time == 0 then
					upcoming_match_switchover()
				else -- else, set up the timer for switching in the future
					switchover_scheduled = true
					obs.timer_add(upcoming_match_switchover_timer_callback, effective_switchover_time*1000)
				end
			end
		end
		-- nothing else to do here
		return
	end
	
	-- else, if we've made it here, we're not between matches
	between_matches = false
	-- see if there was a switchover scheduled that we need to remove now
	if switchover_scheduled then
		obs.timer_remove(upcoming_match_switchover_timer_callback)
		switchover_scheduled = false
	end
	
	-- get match phase and num
	local elem_match_phase_and_num = root_parse:select(".nameAndTimer > h3")
	if next(elem_match_phase_and_num) == nil then
		return
	end
	local match_split_string = {}
	for w in string.gmatch(elem_match_phase_and_num[1]:getcontent(), "([^ ]+)") do
		table.insert(match_split_string, w)
	end
	cur_match_phase = match_split_string[1]
	cur_match_num = tonumber(match_split_string[2])
	--print("==== Current match phase is: ".. cur_match_phase)
	--print("==== Current match number is: ".. cur_match_num)
	
	-- get the field elements
	cur_match_table = {}
	-- TODO - separate out team number from team name. For now, it's all one string.
	local elem_field_elements = root_parse:select(".fields > .field")
	if next(elem_field_elements) == nil then
		return
	end
	for _,e in ipairs(elem_field_elements) do
		local elem_field_num = e:select("table > tr > th")
		if next(elem_field_num) == nil then
			return
		end
		local field_num = string.gsub(elem_field_num[1]:getcontent(), "Field ", "")
		field_num = tonumber(field_num)
		cur_match_table[field_num] = {}
		--print("Field number: " .. field_num)
		for _,color in ipairs({"red", "green", "blue", "yellow"}) do
			local elem_quad = e:select("table > tr > td.light-"..color)
			if next(elem_quad) == nil then
				return
			end
			cur_match_table[field_num][color] = unescape_html(string.match(elem_quad[1]:getcontent(), "^%s*(.-)%s*$"))
			--print("cur_match_table["..field_num.."]["..color.."] = "..cur_match_table[field_num][color])
		end
	end
	
	-- set all of the labels
	set_all_labels_to_current()
end

-- Timer callback for switching over to the upcoming match
function upcoming_match_switchover_timer_callback()
	switchover_scheduled = false
	obs.remove_current_callback()
	upcoming_match_switchover()
end

-- Hotkey callback for switching over to the upcoming match
function upcoming_match_switchover_hotkey_callback(pressed)
	-- pressed == true means the down stroke, vs pressed == false is the release of the key
	if pressed then
		-- only allow changes between matches
		if between_matches then
			-- check if it's already scheduled (need to unschedule if so)
			if switchover_scheduled then
				obs.timer_remove(upcoming_match_switchover_timer_callback)
			end
			upcoming_match_switchover()
		end
	end
end

function upcoming_match_switchover()
	if upcoming_matches ~= nil then
		if cur_match_num == nil or cur_match_num == 0 then
			-- could be an accidental reset in the middle of the match schedule
			-- check the upcoming match table for the lowest number and assume
			-- that's the next match number
			local idx, _ = next(upcoming_matches, nil)
			local lowest_num = idx
			while idx do
				if idx < lowest_num then
					lowest_num = idx
				end
				idx, _ = next(upcoming_matches, idx)
			end
			cur_match_num = lowest_num
			print("Unsure about last match number. Assuming it was " .. cur_match_num .. " based on upcoming match table.")
		else
			-- advance the match_num
			cur_match_num = cur_match_num + 1
		end
			
		if upcoming_matches[cur_match_num] ~= nil then
			cur_match_table = upcoming_matches[cur_match_num]
			set_quadrant_labels(cur_match_table, cur_settings)
			set_timer_label("", cur_settings)
			set_match_label(cur_match_phase, cur_match_num, cur_settings)
		else
			-- no more upcoming matches, that means we've reached the end of the current phase
			-- just clear out the labels
			local blank_table = {}
			for _,color in ipairs({"red", "green", "blue", "yellow"}) do
				blank_table[color] = ""
			end
			set_quadrant_labels(blank_table, cur_settings)
			set_timer_label("", cur_settings)
			set_match_label("", "", cur_settings)
		end
	end
end

-- requests the upcoming matches (from pit display page) and parses it.
-- Returns table indexed by match number, field number, and quadrant color, e.g.
--   ret[14][1]["yellow"] == "DSST: Byers (1310)" -- match 14, field 1, yellow quadrant
function parse_upcoming_matches_table()
	local addr = base_addr .. "/Marquee/PitRefresh"
	local response = request.send(addr)
	
	-- Check for bad response
	if (not response) or (response.code ~= 200) then
		return nil
	end
	
	--print(response.body)
	---- start parsing
	local root_parse = htmlparser.parse(response.body)
	
	local ret = {}
	local elem_rows = root_parse:select("table > tbody > tr")
	if next(elem_rows) == nil then
		return
	end
	for _,elem_row in ipairs(elem_rows) do
		-- get match number and field number
		elem_match_field = elem_row:select("td[style='white-space:nowrap']")
		if next(elem_match_field) == nil then
			-- just skip this row
			-- no proper "continue" in lua, so use a label at the end of this for loop
			goto continue_row_loop
		end
		local match_split_string = {}
		for w in string.gmatch(elem_match_field[1]:getcontent(), "([^ -]+)") do
			table.insert(match_split_string, w)
		end
		local match_num = tonumber(match_split_string[1])
		local field_num = tonumber(match_split_string[2])
		-- create the empty tables if they don't exist yet
		if (ret[match_num] == nil) then  ret[match_num] = {} end
		if (ret[match_num][field_num] == nil) then  ret[match_num][field_num] = {}  end
		for _,color in ipairs({"red", "green", "blue", "yellow"}) do
			local elem_quad = elem_row:select("td."..color)
			if next(elem_quad) ~= nil then
				-- TODO separate team name from team number (all one string for now)
				ret[match_num][field_num][color] = unescape_html(string.match(elem_quad[1]:getcontent(), "^%s*(.-)%s*$"))
			end
		end
		::continue_row_loop::
	end
	
	-- for mnum, mentry in pairs(ret) do
		-- for fnum, fentry in pairs(mentry) do
			-- for ckey, centry in pairs(fentry) do
				-- print("  ret["..mnum.."]["..fnum.."]["..ckey.."] = " .. centry)
			-- end
		-- end
	-- end
	
	return ret
			
end

-- Function to set all labels using the global values
function set_all_labels_to_current()
	-- check if we should use manual time
	if not manual_timer then
		set_timer_label(cur_web_time, cur_settings)
	end
	-- if using manual_timer, then the timer label gets set by the manual timer's countdown callback
	
	-- set match number and (optionally) phase
	set_match_label(cur_match_phase, cur_match_num, cur_settings)
	
	-- only attempt to set quadrant labels if the match table isn't nil
	if cur_match_table ~= nil then
		set_quadrant_labels(cur_match_table, cur_settings)
	end
end

-- Function to set the current timer and match phase / number
--  Note match_phase is only used if the show_match_phase setting is true.
function set_timer_label(timer_text, settings)
	-- set timer label
	if timer_text ~= nil then
		--local timer_source_name = obs.obs_data_get_string(settings, "timer_source")
		if timer_source_name ~= "" then
			-- get the actual source object (must be released later)
			local timer_source = obs.obs_get_source_by_name(timer_source_name)
			if timer_source ~= nil then
				-- create data object for setting the "text" field of the text source (must be released later)
				local text_settings = obs.obs_data_create()
				-- set the string
				obs.obs_data_set_string(text_settings, "text", timer_text)
				-- save the text setting data object to the source
				obs.obs_source_update(timer_source, text_settings)
				-- release the text data object
				obs.obs_data_release(text_settings)
			end
			obs.obs_source_release(timer_source)
		end
	end
end

-- Function to set the current match phase / number
--  Note match_phase is only used if the show_match_phase setting is true.
function set_match_label(match_phase, match_num, settings)
	-- set match label
	if match_num ~= nil then
		-- first, build the match string, checking to see if we need to include phase
		local match_string = ""
		local show_match_phase = obs.obs_data_get_bool(settings, "show_match_phase")
		if (show_match_phase) and (match_phase ~= nil) then
			match_string = match_phase .. " " .. tostring(match_num)
		else
			match_string = tostring(match_num)
		end
		-- now get the source and set the text
		local match_num_source_name = obs.obs_data_get_string(settings, "match_num_source")
		if match_num_source_name ~= "" then
			-- get the actual source object (must be released later)
			local match_num_source = obs.obs_get_source_by_name(match_num_source_name)
			if match_num_source ~= nil then
				-- create data object for setting the "text" field of the text source (must be released later)
				local match_settings = obs.obs_data_create()
				-- set the string
				obs.obs_data_set_string(match_settings, "text", match_string)
				-- save the text setting data object to the source
				obs.obs_source_update(match_num_source, match_settings)
				-- release the text data object
				obs.obs_data_release(match_settings)
			end
			obs.obs_source_release(match_num_source)
		end
	end
		
end


-- Function to set the current match's quadrant labels
--   match_table should be indexed with [field_num][color]
function set_quadrant_labels(match_table, settings)
	for idx=1,num_fields do
		if match_table[idx] ~= nil then
			-- loop through the colors
			for _,color in ipairs({"red", "green", "blue", "yellow"}) do
				if match_table[idx][color] ~= nil then
					local quad_source_name = obs.obs_data_get_string(settings, color .. "_source" .. idx)
					if quad_source_name ~= "" then
						-- get the actual source object (must be released later)
						local quad_source = obs.obs_get_source_by_name(quad_source_name)
						if quad_source ~= nil then
							-- create data object for setting the "text" field of the text source (must be released later)
							local text_settings = obs.obs_data_create()
							-- set the string
							obs.obs_data_set_string(text_settings, "text", match_table[idx][color])
							-- save the text setting data object to the source
							obs.obs_source_update(quad_source, text_settings)
							-- release the text data object
							obs.obs_data_release(text_settings)
						else
							print("Source was nil")
						end
						-- release source object
						obs.obs_source_release(quad_source)
					else
						print("Source name was empty")
					end
				else
					print("Table ["..idx.."]["..color.."] was empty")
				end -- if table entry nil
			end	-- for color
		end -- if match_table[idx] ~= nil
	end -- for idx=1,num_fields
end
	

-- Function to set the time text
function set_manual_timer_text()
	local seconds       = math.floor(cur_manual_timer_seconds % 60)
	local minutes = math.floor(cur_manual_timer_seconds / 60)
	
	local timer_text = string.format("%01d:%02d", minutes, seconds)

	set_timer_label(timer_text, cur_settings)

end

function manual_timer_callback()
	cur_manual_timer_seconds = cur_manual_timer_seconds - 1
	if cur_manual_timer_seconds <= 0 then
		obs.remove_current_callback()
		cur_manual_timer_seconds = 0
	end

	set_manual_timer_text()
end

function activate_manual_timer(activating)
	if timer_activated == activating then
		return
	end

	timer_activated = activating

	if activating then
		set_manual_timer_text()
		obs.timer_add(manual_timer_callback, 1000)
	else
		obs.timer_remove(manual_timer_callback)
	end
end

-- Called when a source is activated/deactivated
function activate_timer_signal(cd, activating)
	local source = obs.calldata_source(cd, "source")
	if source ~= nil then
		local name = obs.obs_source_get_name(source)
		if (name == timer_source_name) then	
			cur_manual_timer_seconds = TIMER_RESET_SECONDS
			activate_manual_timer(activating)
		end
	end
end

function source_activated(cd)
	activate_timer_signal(cd, true)
end

function source_deactivated(cd)
	activate_timer_signal(cd, false)
end

function manual_timer_reset()
	if manual_timer then
		activate_manual_timer(false)
		cur_manual_timer_seconds = TIMER_RESET_SECONDS
		local source = obs.obs_get_source_by_name(timer_source_name)
		if source ~= nil then
			local active = obs.obs_source_active(source)
			obs.obs_source_release(source)
			activate_manual_timer(active)
		end
	end
end

function timer_reset_button_clicked(props, p)
	manual_timer_reset()
	return false
end

----------------------------------------------------------


-- callback function for the base_addr property
function setting_base_addr_modified_cb(props, p, settings)
	local new_base_addr = obs.obs_data_get_string(settings, "base_addr")
	if new_base_addr ~= base_addr then
		-- TODO: error checking?
		if active_parsing_update_timer_callback then
			obs.timer_remove(parsing_update_timer_callback)
			active_parsing_update_timer_callback = false
		end
		if active_connection_timer_callback then
			obs.timer_remove(connection_timer_callback)
		end
		base_addr = obs.obs_data_get_string(settings, "base_addr")
		obs.timer_add(connection_timer_callback, RETRY_TIME)
		active_connection_timer_callback = true
	end
end
	

-- callback function for the num_fields property
function setting_num_fields_modified_cb(props, p, settings)
	num_fields = obs.obs_data_get_int(settings, "num_fields")
	
	local pf2 = obs.obs_properties_get(props, "field2")
	local pf3 = obs.obs_properties_get(props, "field3")
	local pf4 = obs.obs_properties_get(props, "field4")

	
	obs.obs_property_set_visible(pf2, (num_fields >= 2))
	obs.obs_property_set_visible(pf3, (num_fields >= 3))
	obs.obs_property_set_visible(pf4, (num_fields >= 4))
	
	return true
end

-- callback function for the manual_timer property
function setting_manual_timer_modified_cb(props, p, settings)
	local old_manual_timer = manual_timer
	manual_timer = obs.obs_data_get_bool(settings, "manual_timer")
	-- make reset button visible
	local p_timer_reset_btn = obs.obs_properties_get(props, "timer_reset_btn")
	obs.obs_property_set_visible(p_timer_reset_btn, manual_timer)
	
	if manual_timer and not old_manual_timer then -- from false to true
		-- convert web_time to seconds time, if needed
		if cur_web_time ~= nil and cur_web_time ~= "" then
			-- split around the :
			local match_split_string = {}
			for w in string.gmatch(cur_web_time, "([^:]+)") do
				table.insert(match_split_string, w)
			end
			if (match_split_string[1] ~= nil and match_split_string[2] ~= nil) then
				cur_manual_timer_seconds = tonumber(match_split_string[1])*60 + tonumber(match_split_string[2])
			else
				cur_manual_timer_seconds = 0
			end
		else
			cur_manual_timer_seconds = 0
		end
			
		if cur_manual_timer_seconds > 0 then
			-- activate countdown timer
			activate_manual_timer(true)
		end
	elseif not manual_timer and old_manual_timer then -- from true to false
		-- deactivate the timer
		activate_manual_timer(false)
	end
	
	return true
end

-- callback function for the auto_switchover property
function setting_auto_switchover_modified_cb(props, p, settings)
	auto_switchover = obs.obs_data_get_bool(settings, "auto_switchover")
	local p_upcoming_time = obs.obs_properties_get(props, "upcoming_time")
	obs.obs_property_set_visible(p_upcoming_time, auto_switchover)
	return true
end

-- callback for any of the field quadrant source properties
function setting_quad_source_modified_cb(props, p, settings)
	if cur_match_table ~= nil then
		set_quadrant_labels(cur_match_table, settings)
	end
	return false
end

-- callback for the timer source property
function setting_timer_source_modified_cb(props, p, settings)
	timer_source_name = obs.obs_data_get_string(settings, "timer_source")
	set_timer_label(timer_text, settings)
	return false
end

-- callback for the match num source property
function setting_match_num_source_modified_cb(props, p, settings)
	set_match_label(cur_match_phase, cur_match_num, settings)
	return false
end

-- callback for the status text property
function setting_net_status_modified_cb(props, p, settings)
	print("In setting_net_status_modified_cb")
	--obs.obs_property_set_visible(p, false)
	--obs.obs_property_set_visible(p, true)
	return true
end
	

-- A function named script_properties defines the properties that the user
-- can change for the entire script module itself
function script_properties()
	local props = obs.obs_properties_create()
	
	local p_base_addr = obs.obs_properties_add_text(props, "base_addr", "Base network address,\ne.g. \"http://<ip-addr>:9268\"", obs.OBS_TEXT_DEFAULT)
	obs.obs_property_set_modified_callback(p_base_addr, setting_base_addr_modified_cb)
	--local p_connect_btn = obs.obs_properties_add_button(props, "connect_btn", "Connect to PCSM", connect_button_clicked)
	p_net_status = obs.obs_properties_add_text(props, "net_status", "Connection status:", obs.OBS_TEXT_INFO)
	obs.obs_property_text_set_info_type(p_net_status, obs.OBS_TEXT_INFO_ERROR)
	-- TODO: Fix the net_status, if possible, it's not updating properly. For now, just hide it.
	obs.obs_property_set_visible(p_net_status, false)
	--obs.obs_property_set_modified_callback(p_net_status, setting_net_status_modified_cb)
		
	local pnf = obs.obs_properties_add_int(props, "num_fields", "Expected number of fields", 1, 4, 1)
	obs.obs_property_set_modified_callback(pnf, setting_num_fields_modified_cb)
	
	local p_timer_source = obs.obs_properties_add_list(props, "timer_source", "Timer: Text Source", obs.OBS_COMBO_TYPE_EDITABLE, obs.OBS_COMBO_FORMAT_STRING)
	-- ^ enumerations are added later
	obs.obs_property_set_modified_callback(p_timer_source, setting_timer_source_modified_cb)
	
	local p_manual_timer = obs.obs_properties_add_bool(props, "manual_timer", "Use manual timer\ninstead of PCSM timer.")
	obs.obs_property_set_long_description(p_manual_timer, "When selected, timer from PCSM is ignored, timer restarts\n"..
														  "on becoming visible or resets with button click or hotkey")
	obs.obs_property_set_modified_callback(p_manual_timer, setting_manual_timer_modified_cb)
	
	local p_timer_reset_btn = obs.obs_properties_add_button(props, "timer_reset_btn", "Reset Timer", timer_reset_button_clicked)
	
	local p_auto_switchover = obs.obs_properties_add_bool(props, "auto_switchover", "Automatically switch labels\n"..
																					"after the match ends.")
	obs.obs_property_set_long_description(p_auto_switchover, "When selected, the labels will get switch to show the next\n"..
															 "upcoming match a specified amount of time after a match ends.\n"..
															 "Without this selected, labels can still be switched manually\n"..
															 "by using a hotkey binding.")
	obs.obs_property_set_modified_callback(p_auto_switchover, setting_auto_switchover_modified_cb)
	
	local p_upcoming_time = obs.obs_properties_add_float(props, "upcoming_time", "Post-match label\nswitchover time", 0, 300, 0.001)
	obs.obs_property_set_long_description(p_upcoming_time, "Amount of time in seconds after a match ends to wait before " ..
                                                           "automatically switching labels to the next upcoming match.")
	
	local p_match_num_source = obs.obs_properties_add_list(props, "match_num_source", "Match Number: Text Source", obs.OBS_COMBO_TYPE_EDITABLE, obs.OBS_COMBO_FORMAT_STRING)
	-- ^ enumerations are added later
	obs.obs_property_set_modified_callback(p_match_num_source, setting_match_num_source_modified_cb)
	
	local p_show_match_phase = obs.obs_properties_add_bool(props, "show_match_phase", "Include match phase\nwith the match number.")
	
	local group_props = {}
	local gp_srclist = {}
	local group_props_prop = {}
	
	for idx = 1,4 do
		group_props[idx] = obs.obs_properties_create()
		group_props_prop[idx] = obs.obs_properties_add_group(props, "field" .. idx, "Field " .. idx, obs.OBS_GROUP_NORMAL, group_props[idx])
		
		gp_srclist[idx] = {}
		
		gp_srclist[idx][1] = obs.obs_properties_add_list(group_props[idx], "red_source" .. idx, "Red: Text Source", obs.OBS_COMBO_TYPE_EDITABLE, obs.OBS_COMBO_FORMAT_STRING)
		gp_srclist[idx][2] = obs.obs_properties_add_list(group_props[idx], "green_source" .. idx, "Green: Text Source", obs.OBS_COMBO_TYPE_EDITABLE, obs.OBS_COMBO_FORMAT_STRING)
		gp_srclist[idx][3] = obs.obs_properties_add_list(group_props[idx], "yellow_source" .. idx, "Yellow: Text Source", obs.OBS_COMBO_TYPE_EDITABLE, obs.OBS_COMBO_FORMAT_STRING)
		gp_srclist[idx][4] = obs.obs_properties_add_list(group_props[idx], "blue_source" .. idx, "Blue: Text Source", obs.OBS_COMBO_TYPE_EDITABLE, obs.OBS_COMBO_FORMAT_STRING)
		-- ^ enumerations are added later
		obs.obs_property_set_modified_callback(gp_srclist[idx][1], setting_quad_source_modified_cb)
		obs.obs_property_set_modified_callback(gp_srclist[idx][2], setting_quad_source_modified_cb)
		obs.obs_property_set_modified_callback(gp_srclist[idx][3], setting_quad_source_modified_cb)
		obs.obs_property_set_modified_callback(gp_srclist[idx][4], setting_quad_source_modified_cb)
	end

	-- now we add in the source enumerations for all the text-source dropdown properties
	local sources = obs.obs_enum_sources()
	if sources ~= nil then
		for _, source in ipairs(sources) do
			source_id = obs.obs_source_get_unversioned_id(source)
			if source_id == "text_gdiplus" or source_id == "text_ft2_source" then
				local name = obs.obs_source_get_name(source)
				obs.obs_property_list_add_string(p_timer_source, name, name)
				obs.obs_property_list_add_string(p_match_num_source, name, name)
				for gidx = 1,4 do
					for cidx = 1,4 do
						obs.obs_property_list_add_string(gp_srclist[gidx][cidx], name, name)
					end
				end

			end
		end
	end
	obs.source_list_release(sources)
	
	global_props = props
	
	-- Calls the callbacks once to set-up current visibility.
	-- Without this, the visibility will initially be wrong on loading / refreshing the script.
	obs.obs_properties_apply_settings(props, cur_settings)

	return props
end

-- A function named script_description returns the description shown to
-- the user
function script_description()
	return "For use with BEST Robotics PC Scoring Manager.\nThis scrapes the marquee page to get the teams in each quadrant, plus the current timer.\nMade by Ben Straub"
end

-- A function named script_update will be called when settings are changed
function script_update(settings)
	-- save off the current settings
	cur_settings = settings
	return true
end

-- A function named script_defaults will be called to set the default settings
function script_defaults(settings)
	--obs.obs_data_set_default_string(settings, "base_addr", "http://127.0.0.1:9268")
	obs.obs_data_set_default_string(settings, "base_addr", "")
	obs.obs_data_set_default_int(settings, "num_fields", 1)
	obs.obs_data_set_default_bool(settings, "manual_timer", false)
	
	obs.obs_data_set_default_string(settings, "net_status", "Disconnected.")

end

-- A function named script_save will be called when the script is saved
--
-- NOTE: This function is usually used for saving extra data (such as in this
-- case, a hotkey's save data).  Settings set via the properties are saved
-- automatically.
function script_save(settings)
	-- save hotkey for manual timer reset
	local manual_timer_reset_hotkey_save_array = obs.obs_hotkey_save(manual_timer_reset_hotkey_id)
	obs.obs_data_set_array(settings, "BEST_parser_reset_manual_timer", manual_timer_reset_hotkey_save_array)
	obs.obs_data_array_release(manual_timer_reset_hotkey_save_array)
	-- save hotkey for upcoming match switchover
	local upcoming_switchover_hotkey_save_array = obs.obs_hotkey_save(upcoming_switchover_hotkey_id)
	obs.obs_data_set_array(settings, "BEST_parser_upcoming_switchover", upcoming_switchover_hotkey_save_array)
	obs.obs_data_array_release(upcoming_switchover_hotkey_save_array)
end

-- a function named script_load will be called on startup
function script_load(settings)
	-- erase the setting for net_status (clear out old status)
	--obs.obs_data_erase(settings, "net_status")
	obs.obs_data_set_string(settings, "net_status", "Disconnected.")
	
	-- Connect activation/deactivation signal callbacks
	--
	-- NOTE: These particular script callbacks do not necessarily have to
	-- be disconnected, as callbacks will automatically destroy themselves
	-- if the script is unloaded.  So there's no real need to manually
	-- disconnect callbacks that are intended to last until the script is
	-- unloaded.
	local sh = obs.obs_get_signal_handler()
	obs.signal_handler_connect(sh, "source_activate", source_activated)
	obs.signal_handler_connect(sh, "source_deactivate", source_deactivated)

	-- register the hotkeys
	manual_timer_reset_hotkey_id = obs.obs_hotkey_register_frontend("BEST_parser_reset_manual_timer",
																	"BEST Parser Script: Reset Manual Timer",
																	manual_timer_reset)
	upcoming_switchover_hotkey_id = obs.obs_hotkey_register_frontend("BEST_parser_upcoming_switchover",
																     "BEST Parser Script: Switchover to Upcoming Match",
																	 upcoming_match_switchover_hotkey_callback)
	
	-- load the hotkeys:
	-- load the manual timer reset's saved hotkey array (must be released later)
	local manual_timer_reset_hotkey_save_array = obs.obs_data_get_array(settings, "BEST_parser_reset_manual_timer")
	obs.obs_hotkey_load(manual_timer_reset_hotkey_id, manual_timer_reset_hotkey_save_array)
	obs.obs_data_array_release(manual_timer_reset_hotkey_save_array)
	-- load the upcoming switchover's saved hotkey array (must be released later)
	local upcoming_switchover_hotkey_save_array = obs.obs_data_get_array(settings, "BEST_parser_upcoming_switchover")
	obs.obs_hotkey_load(upcoming_switchover_hotkey_id, upcoming_switchover_hotkey_save_array)
	obs.obs_data_array_release(upcoming_switchover_hotkey_save_array)
	

end
