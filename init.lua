lualandmg = {}
local mod_path = minetest.get_modpath("lualandmg")

-- Default noise params
lualandmg.np_base = {
	offset = 0,
	scale = 1,
	spread = {x=256, y=256, z=256},
	octaves = 5,
	seed = 42692,
	persist = 0.5
}

lualandmg.np_mountains = {
	offset = 0,
	scale = 1,
	spread = {x=256, y=256, z=256},
	octaves = 5,
	seed = 3853,
	persist = 0.5
}

lualandmg.np_trees = {
	offset = 0,
	scale = 1,
	spread = {x=64, y=64, z=64},
	octaves = 1,
	seed = -5432,
	persist = 0.6
}

lualandmg.np_caves = {
	offset = 0,
	scale = 1,
	spread = {x=32, y=16, z=32},
	octaves = 4,
	seed = -11842,
	persist = 0.4,
	flags = "eased"
}

-- A value between: 0.0 and 100.0
lualandmg.np_temperature = {
	offset = 0,
	scale = 1,
	spread = {x=512, y=512, z=512},
	octaves = 2,
	seed = 921498,
	persist = 0.5
}

dofile(mod_path.."/settings.lua")
dofile(mod_path.."/nodes.lua")
dofile(mod_path.."/functions.lua")
dofile(mod_path.."/treegen.lua")
dofile(mod_path.."/biomedef.lua")

-- Apply noise modifier settings
local np_list = {"np_base", "np_mountains", "np_trees", "np_temperature"}
for _,v in pairs(np_list) do
	lualandmg[v].spread = vector.multiply(
		lualandmg[v].spread, lualandmg.noise_spread)
end

minetest.set_mapgen_setting("mgname", "singlenode", true)

minetest.register_chatcommand("regenerate", {
	description = "Regenerates <size * 8>^3 nodes around you",
	params = "<size * 8>",
	privs = {server=true},
	func = function(name, param)
		local size = tonumber(param) or 1

		if size > 8 then
			size = 8 -- Limit: 8*8 -> 64
		elseif size < 1 then
			return false, "Nothing to do."
		end

		size = size * 8
		local player = minetest.get_player_by_name(name)
		local pos = vector.floor(vector.divide(player:getpos(), size))
		local minp = vector.multiply(pos, size)
		local maxp = vector.add(minp, size - 1)

		lualandmg.generate(minp, maxp, math.random(0, 9999), true)
		return true, "Done!"
	end
})

local c_air    = minetest.get_content_id("air")
local c_water  = minetest.get_content_id("default:water_source")
local c_lava   = minetest.get_content_id("default:lava_source")
local c_stone  = minetest.get_content_id("default:stone")
local c_ice    = minetest.get_content_id("default:ice")
local c_cactus = minetest.get_content_id("default:cactus")
local heightmap = {}
local heatmap = {}

local old_funct = minetest.get_mapgen_object
function minetest.get_mapgen_object(what)
	if what == "heightmap" then
		return heightmap
	end
	if what == "heatmap" then
		return heatmap
	end
	return old_funct(what)
end

function lualandmg.generate(minp, maxp, seed, regen)
	local is_surface = maxp.y > -80

	local t1 = os.clock()
	local sidelen1d = maxp.x - minp.x + 1
	local sidelen3d = {x=sidelen1d, y=sidelen1d, z=sidelen1d}
	heightmap = {}
	heatmap = {}

	local terrain_scale = lualandmg.terrain_scale
	local trees = lualandmg.registered_trees
	local surface = {}
	local mudflow_check = {}

	local nvals_base, nvals_mountains, nvals_trees, nvals_temp
	if is_surface then
		-- Update the perlin maps if required
		if lualandmg.pm_sidelen ~= sidelen1d then
			lualandmg.pm_base      = minetest.get_perlin_map(lualandmg.np_base, sidelen3d)
			lualandmg.pm_mountains = minetest.get_perlin_map(lualandmg.np_mountains, sidelen3d)
			lualandmg.pm_trees     = minetest.get_perlin_map(lualandmg.np_trees, sidelen3d)
			lualandmg.pm_temp      = minetest.get_perlin_map(lualandmg.np_temperature, sidelen3d)
			lualandmg.pm_sidelen = sidelen1d
		end

		nvals_base      = lualandmg.pm_base:get_2d_map_flat({x=minp.x, y=minp.z})
		nvals_mountains = lualandmg.pm_mountains:get_2d_map_flat({x=minp.x, y=minp.z})
		nvals_trees     = lualandmg.pm_trees:get_2d_map_flat({x=minp.x, y=minp.z})
		nvals_temp      = lualandmg.pm_temp:get_2d_map_flat({x=minp.x, y=minp.z})
	end

	-- Pre-calculate terrain height, biome and trees
	local nixz = 1
	if is_surface then
		local biomes = lualandmg.registered_biomes
		local decorations = lualandmg.registered_decorations
		for z = minp.z, maxp.z do
		for x = minp.x, maxp.x do
			local surf        = nvals_base[nixz] * 20 + 16
			local mountain_y  = nvals_mountains[nixz] * 80 - 30
			local tree_factor = nvals_trees[nixz] * 5 + 4
			local temperature = nvals_temp[nixz] * 43 + 17
			local tree = nil

			-- 'j_*' used for jitter/spread values
			local j_temperature = temperature + math.random(-3, 3)

			if mountain_y > 0 then
				surf = surf + mountain_y
			end

			if surf < 0 then
				-- Deeper oceans
				surf = surf * 2.5
			end

			surf = math.floor((surf * terrain_scale) + 0.5)
			if math.abs(temperature - 45) < 5 then
				-- Prevent lakes in deserts
				surf = math.floor(
					math.max(-math.abs(temperature - 45) * 5, surf) + 0.5)
			end
			local g_stone, g_middle, g_top, g_cover

			for i, v in ipairs(biomes) do
				if j_temperature > v.temperature_min or i == #biomes then
					g_stone  = v.stone
					g_middle = v.middle
					g_top    = v.top
					g_cover  = v.cover
					break
				end
			end

			if not g_cover then
				for i, v in pairs(decorations) do
					if j_temperature >= v.temperature_min and
							j_temperature <= v.temperature_max and
							math.random(v.chance) == 1 then
	
						if lualandmg.is_valid_ground(v.node_under, g_top) then
							g_cover = v.name
							break
						end
					end
				end
			end

			-- Tweak the noise a bit
			tree_factor = tree_factor * tree_factor
			if tree_factor < 0.4 then
				tree_factor = 0.4
			end

			for i, v in pairs(trees) do
				if j_temperature >= v.temperature_min and
						j_temperature <= v.temperature_max and
						math.random(math.ceil(v.chance * tree_factor)) == 1 then

					if lualandmg.is_valid_ground(v.node_under, g_top) then
						tree = v
						g_cover = nil
						break
					end
				end
			end

			surface[nixz] = {surf, tree, temperature,
					g_stone, g_middle, g_top, g_cover}
			nixz = nixz + 1
		end
		end
		nvals_base = nil
		nvals_mountains = nil
		nvals_trees = nil
	end


	local vm, emin, emax
	if regen then
		vm = minetest.get_voxel_manip()
		emin, emax = vm:read_from_map(minp, maxp)
	else
		vm, emin, emax = minetest.get_mapgen_object("voxelmanip")
	end

	local area = VoxelArea:new{MinEdge=emin, MaxEdge=emax}
	local data = vm:get_data()

	if regen then
		-- Erase the entire area
		for z = minp.z, maxp.z do
		for y = minp.y, maxp.y do
			local vi = area:index(minp.x, y, z)
			for x = minp.x, maxp.x do
				data[vi] = c_air
				vi = vi + 1
			end
		end
		end
	end

	local nvals_caves = minetest.get_perlin_map(lualandmg.np_caves, sidelen3d):get_3d_map_flat(minp)
	local nixyz = 1
	nixz = 1

	-- Lava occurrence coefficient, maximal lava at Y=-4096
	local lava_coeff = math.max(minp.y / 4096, -1) / 5
	for z = minp.z, maxp.z do
	for y = minp.y, maxp.y do
		local vi = area:index(minp.x, y, z)
		for x = minp.x, maxp.x do
			local surf, tree, temp = 0, 0, 0
			local g_stone = c_stone
			local g_middle, g_top, g_cover

			if is_surface then
				local cache = surface[nixz]
				surf = cache[1]
				tree = cache[2]
				temp = cache[3]

				g_stone  = cache[4]
				g_middle = cache[5]
				g_top    = cache[6]
				g_cover  = cache[7]
			end
			local cave = nvals_caves[nixyz]

			if cave > 1.1 + lava_coeff and y < -20
					and not (is_surface and temp < 5) then
				-- Cave, filled with lava
				if cave > 1.3 + lava_coeff then
					data[vi] = c_lava
				end
			elseif cave < -0.9 + lava_coeff / 2 and y <= surf + 1 then
				-- Empty cave
				if is_surface then
					mudflow_check[nixz] = true
				end
			elseif y == surf and y < 0 then
				-- Sea ground
				data[vi] = g_middle
			elseif y == surf then
				-- Surface, maybe with a tree above
				if tree then
					tree.action(
						vector.new(x, y + 1, z),
						vm, data, area, seed
					)
					data[vi] = g_middle
				else
					data[vi] = g_top
				end
			elseif y == surf + 1 and y > 0 and g_cover then
				if data[vi] == c_air then
					if data[area:index(x, y - 1, z)] == g_top then
						data[vi] = g_cover
					end
				end
			elseif surf - y <= (3 - surf / 30) and y < surf then
				-- Soil/sand under the surface
				data[vi] = g_middle
			elseif y > surf and y <= 0  then
				-- Water
				if temp + math.random(-2, 2) < -18 then
					data[vi] = c_ice
				elseif temp < 45 then
					data[vi] = c_water
				end
			elseif y < surf then
				data[vi] = g_stone
			end

			nixyz = nixyz + 1
			nixz = nixz + 1
			vi = vi + 1
		end
		nixz = nixz - sidelen1d
	end
	nixz = nixz + sidelen1d
	end
	nvals_caves = nil

	local t2 = os.clock()
	local log_message = minetest.pos_to_string(minp).." terrain = "..
			math.ceil((t2 - t1) * 1000)

	if is_surface then
		-- Do the mudflow!
		nixz = 1
		local height = 2
		for z = minp.z, maxp.z do
		for x = minp.x, maxp.x do
			if mudflow_check[nixz] then
				local cache = surface[nixz]
				local r_surf = cache[1]
				local surf = r_surf + height
				local g_stone  = cache[4]
				local g_middle = cache[5]
				local g_top    = cache[6]

				-- out of range
				if r_surf - 16 > maxp.y then
					surf = minp.y + 1
				end

				-- node at surface got removed
				local max_depth = 5
				local vi, node, ground
				local depth = 0
				local covered, water = false, false
				for y = surf, minp.y + 1, -1 do
					vi = area:index(x, y, z)
					node = data[vi]
					local is_air = (node == c_air)

					if node == c_water then
						water = true
					end

					if depth >= max_depth then
						ground = y + max_depth
						break
					end

					if is_air then
						if water then
							-- Fill up caves to prevent massive flood
							data[vi] = c_water
						elseif depth > 0 then
							covered = true
							data[vi] = g_stone
						end
						depth = 0
					elseif y <= r_surf then
						depth = depth + 1
					end
				end

				if ground and ground ~= surf then
					vi = area:index(x, ground, z)
					if ground >= 0 and not covered then
						data[vi] = g_top
						-- Update terrain height for heightmap
						cache[1] = ground
					else
						data[vi] = g_middle
					end
					vi = area:index(x, ground - 1, z)
					data[vi] = g_middle
				end
			end
			heightmap[nixz] = surface[nixz][1]
			heatmap[nixz] = nvals_temp[nixz] * 50 + 50
			nixz = nixz + 1
		end
		end

		log_message = log_message..", mudflow = "..
			math.ceil((os.clock() - t2) * 1000)
	end

	vm:set_data(data)
	if regen then
		vm:set_param2_data({})
	else
		vm:set_lighting({day=0, night=0})
	end
	minetest.generate_ores(vm)

	vm:calc_lighting()
	vm:write_to_map()
	vm:update_liquids()

	log_message = log_message..", total = "..
		math.ceil((os.clock() - t1) * 1000).." [ms]"
	minetest.log("action", log_message)
end

minetest.after(0, table.insert,
	minetest.registered_on_generateds, 1, lualandmg.generate)