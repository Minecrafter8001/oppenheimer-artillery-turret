local N = require("lib.names")
local copies = {}

for name, source_name in pairs(N.tile_sources) do
	local source = data.raw.tile[source_name]
	if source then
		local tile = table.deepcopy(source)
		tile.name = name
		tile.localised_name = source.localised_name or {"tile-name." .. source_name}
		tile.autoplace = nil
		tile.hidden_in_factoriopedia = true
		tile.fluid = nil
		tile.minable = nil
		tile.placeable_by = nil
		tile.subgroup = "terrain"
		tile.allows_being_covered = not N.hot_tiles[name]
		if not N.hot_tiles[name] and name == N.nauvis_tiles[N.prefix .. source_name] then
			tile.subgroup = "nauvis-tiles"
		end
		copies[#copies + 1] = tile
	end
end

table.sort(copies, function(left, right) return left.name < right.name end)
data:extend(copies)
