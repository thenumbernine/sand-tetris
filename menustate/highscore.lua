local table = require 'ext.table'
local range = require 'ext.range'
local ops = require 'ext.op'
local ig = require 'imgui'
local sandModelClassNames = require 'sand-attack.sandmodel.all'.classNames
local MenuState = require 'sand-attack.menustate.menustate'

local HighScoreState = MenuState:subclass()

function HighScoreState:init(app, needsName)
	HighScoreState.super.init(self, app)
	self.needsName = needsName
	self.name = ''
end

-- save state info pertinent to the gameplay
-- TODO save recording of all keystrokes and game rand seed?
HighScoreState.fields = table{
	'name',
	'lines',
	'level',
	'score',
	'numColors',
	'numPlayers',
	'boardWidth',
	'boardHeight',
	'toppleChance',
	'voxelsPerBlock',
	'sandModel',
	'speedupCoeff',
}

function HighScoreState:makeNewRecord()
	local app = self.app
	local record = {}
	for _,field in ipairs(self.fields) do
		if field == 'name' then
			record[field] = self[field]
		elseif field == 'toppleChance'
		or field == 'voxelsPerBlock'
		or field == 'numColors'
		or field == 'speedupCoeff'
		then
			record[field] = app.cfg[field]
		elseif field == 'sandModel' then
			record[field] = sandModelClassNames[app.cfg[field]]
		elseif field == 'boardWidth' then
			record[field] = tonumber(app.cfg.boardSizeInBlocks.x)
		elseif field == 'boardHeight' then
			record[field] = tonumber(app.cfg.boardSizeInBlocks.y)
		else
			record[field] = app[field]
		end
	end
	return record
end

function HighScoreState:updateGUI()
	local app = self.app
	self:beginFullView'High Scores:'

	-- TODO separate state for this?
	if self.needsName then
		ig.igText'Your Name:'
		ig.luatableTooltipInputText('Your Name', self, 'name')
		if ig.igButton'Ok' then
			self.needsName = false
			local record = self:makeNewRecord()
			table.insert(app.highscores, record)
			table.sort(app.highscores, function(a,b)
				return a.score > b.score
			end)
			app:saveHighScores()
		end
		ig.igNewLine()
	end

	if ig.igBeginTable('High Scores', #self.fields, bit.bor(
		--[[
		ig.ImGuiTableFlags_SizingFixedFit,
		ig.ImGuiTableFlags_ScrollX,
		ig.ImGuiTableFlags_ScrollY,
		ig.ImGuiTableFlags_RowBg,
		ig.ImGuiTableFlags_BordersOuter,
		ig.ImGuiTableFlags_BordersV,
		ig.ImGuiTableFlags_Resizable,
		ig.ImGuiTableFlags_Reorderable,
		ig.ImGuiTableFlags_Hideable,
		ig.ImGuiTableFlags_Sortable
		--]]
		-- [[
		ig.ImGuiTableFlags_Resizable,
		ig.ImGuiTableFlags_Reorderable,
		--ig.ImGuiTableFlags_Hideable,
		ig.ImGuiTableFlags_Sortable,
		ig.ImGuiTableFlags_SortMulti,
		--ig.ImGuiTableFlags_RowBg,
		ig.ImGuiTableFlags_BordersOuter,
		ig.ImGuiTableFlags_BordersV,
		--ig.ImGuiTableFlags_NoBordersInBody,
		--ig.ImGuiTableFlags_ScrollY,
		--]]
	0), ig.ImVec2(0,0), 0) then

		for i,field in ipairs(self.fields) do
			ig.igTableSetupColumn(tostring(field), bit.bor(
					ig.ImGuiTableColumnFlags_DefaultSort
				),
				0,
				i	-- ColumnUserID in the sort
			)
		end
		ig.igTableHeadersRow()
		local sortSpecs = ig.igTableGetSortSpecs()
		if not self.rowindexes or #self.rowindexes ~= #app.highscores then
			self.rowindexes = range(#app.highscores)
		end
		if sortSpecs[0].SpecsDirty then
			local typescore = {
				string = 1,
				number = 2,
				table = 3,
				['nil'] = math.huge,
			}
			-- sort from imgui_demo.cpp CompareWithSortSpecs
			-- TODO maybe put this in lua-imgui
			table.sort(self.rowindexes, function(ia,ib)
				local a = app.highscores[ia]
				local b = app.highscores[ib]
				for n=0,sortSpecs[0].SpecsCount-1 do
					local sortSpec = sortSpecs[0].Specs[n]
					local col = sortSpec.ColumnUserID
					local field = self.fields[tonumber(col)]
					local afield = a[field]
					local bfield = b[field]
					local tafield = type(afield)
					local tbfield = type(bfield)
--print('testing', afield, bfield, tafield, tbfield)
					if afield ~= bfield then
						local op = sortSpec.SortDirection == ig.ImGuiSortDirection_Ascending and ops.lt or ops.gt
						if tafield ~= tbfield then
							-- put nils last ... score for type?
							return op(typescore[tafield], typescore[tbfield])
						end
						return op(afield, bfield)
					end
				end
				return ia < ib
			end)
			sortSpecs[0].SpecsDirty = false
		end
		for _,i in ipairs(self.rowindexes) do
			local score = app.highscores[i]
			ig.igTableNextRow(0, 0)
			for _,field in ipairs(self.fields) do
				ig.igTableNextColumn()
				ig.igText(tostring(score[field]))
			end
		end
		ig.igEndTable()
	end
	if ig.igButton'Done' then
		self.needsName = false
		local MainMenuState = require 'sand-attack.menustate.main'
		app.menustate = MainMenuState(app)
	end
	if not self.needsName then
		ig.igSameLine()
		if ig.igButton'Clear' then
			app.highscores = {}
			app:saveHighScores()
		end
	end
	self:endFullView()
end

return HighScoreState