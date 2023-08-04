local ffi = require 'ffi'
local sdl = require 'ffi.req' 'sdl'
local table = require 'ext.table'
local path = require 'ext.path'
local class = require 'ext.class'
local math = require 'ext.math'
local string = require 'ext.string'
local range = require 'ext.range'
local fromlua = require 'ext.fromlua'
local tolua = require 'ext.tolua'
local template = require 'template'
local matrix = require 'matrix.ffi'
local Image = require 'image'
local gl = require 'gl'
local GLTex2D = require 'gl.tex2d'
local GLProgram = require 'gl.program'
local GLArrayBuffer = require 'gl.arraybuffer'
local GLFBO = require 'gl.fbo'
local glreport = require 'gl.report'
local vec2i = require 'vec-ffi.vec2i'
local vec2f = require 'vec-ffi.vec2f'
local vec3f = require 'vec-ffi.vec3f'
local getTime = require 'ext.timer'.getTime
local ig = require 'imgui'
local ImGuiApp = require 'imguiapp'
local Audio = require 'audio'
local AudioSource = require 'audio.source'
local AudioBuffer = require 'audio.buffer'
local Player = require 'sand-attack.player'
local SandModel = require 'sand-attack.sandmodel.sandmodel'
local sandModelClasses = require 'sand-attack.sandmodel.all'.classes

-- I'm trying to make reproducible random #s
-- it is reproducible up to the generation of the next pieces
-- but the very next piece after will always be dif
-- this maybe is due to the sand toppling also using rand?
-- but why wouldn't that random() call even be part of the determinism?
-- seems something external must be contributing?
--[[ TODO put this in ext? or its own lib?
local RNG = class()
-- TODO max and the + and % constants are bad, fix them
RNG.max = 2147483647ull
require 'ffi.req' 'c.time'
function RNG:init(seed)
	self.seed = ffi.cast('uint64_t', tonumber(seed) or ffi.C.time(nil))
end
function RNG:next(max)
	self.seed = self.seed * 1103515245ull + 12345ull
	return self.seed % (self.max + 1)
end
function RNG:__call(max)
	if max then
		return tonumber(self:next() % max) + 1	-- +1 for lua compat
	else
		return tonumber(self:next()) / tonumber(self.max)
	end
end
--]]
-- [[ Lua code says: xoshira256** algorithm
-- but is only a singleton...
local RNG = class()
function RNG:init(seed)
	math.randomseed(seed)
end
function RNG:__call(...)
	return math.random(...)
end
--]]



local App = class(ImGuiApp)

App.title = 'Sand Attack'
App.sdlInitFlags = bit.bor(
	sdl.SDL_INIT_VIDEO,
	sdl.SDL_INIT_JOYSTICK
)

App.useAudio = true	-- set to false to disable audio altogether
App.showFPS = true -- show fps in gui / console
App.showDebug = false	-- show some more debug stuff
local dontCheckForLinesEver = false	-- means don't ever ever check for lines.  used for fps testing the sand topple simulation.

App.updateInterval = 1/60
--App.updateInterval = 1/120
--App.updateInterval = 0

App.defaultColors = table{
	{1,0,0},
	{0,0,1},
	{0,1,0},
	{1,1,0},
	{1,0,1},
	{0,1,1},
	{1,1,1},
}

App.maxAudioDist = 10

App.chainDuration = 2
App.lineFlashDuration = 1
App.lineNumFlashes = 5

App.cfgfilename = 'config.lua'
App.highScoresFilename = 'highscores.lua'

function App:initGL(...)
	App.super.initGL(self, ...)

	-- populate # colors
	-- don't worry about rng?  or should i seed this by some default value?
	-- I am saving them anyways for the case of color customization, so if you remove a few color and re-add them it remembers
	-- TODO maybe only generate/save colors that have been used so far?
	while #self.defaultColors < 255 do
		self.defaultColors:insert{vec3f():map(function()
			return math.random()
		end):normalize():unpack()}
	end
	-- ... but not all 8 bit alpha channels are really 8 bits ...


	-- allow keys to navigate menu
	-- TODO how to make it so player keys choose menus, not just space bar/
	-- or meh?
	local io = ig.igGetIO()
	io[0].ConfigFlags = bit.bor(
		io[0].ConfigFlags,
		ig.ImGuiConfigFlags_NavEnableKeyboard,
		ig.ImGuiConfigFlags_NavEnableGamepad
	)
	io[0].FontGlobalScale = 2

-- [[ imgui custom font
	--local fontfile = 'font/moenstrum.ttf'				-- no numbers
	--local fontfile = 'font/PixelGamer-Regular.otf'	-- no numbers
	--local fontfile = 'font/goldingots.ttf'
	local fontfile = 'font/Billow twirl Demo.ttf'
	self.fontAtlas = ig.ImFontAtlas_ImFontAtlas()
	self.font = ig.ImFontAtlas_AddFontFromFileTTF(self.fontAtlas, fontfile, 16, nil, nil)
	-- just change the font, and imgui complains that you need to call FontAtlas::Build() ...
	assert(ig.ImFontAtlas_Build(self.fontAtlas))
	-- just call FontAtlas::Build() and you just get white blobs ...
	-- is this proper behavior?  or a bug in imgui?
	-- you have to download the font texture pixel data, make a GL texture out of it, and re-upload it
	local width = ffi.new('int[1]')
	local height = ffi.new('int[1]')
	local bpp = ffi.new('int[1]')
	local outPixels = ffi.new('unsigned char*[1]')
	-- GL_LUMINANCE textures are deprecated ... khronos says use GL_RED instead ... meaning you have to write extra shaders for greyscale textures to be used as greyscale in opengl ... ugh
	--ig.ImFontAtlas_GetTexDataAsAlpha8(self.fontAtlas, outPixels, width, height, bpp)
	ig.ImFontAtlas_GetTexDataAsRGBA32(self.fontAtlas, outPixels, width, height, bpp)
	self.fontTex = GLTex2D{
		internalFormat = gl.GL_RGBA,
		--internalFormat = gl.GL_RED,
		format = gl.GL_RGBA,
		--format = gl.GL_RED,
		width = width[0],
		height = height[0],
		type = gl.GL_UNSIGNED_BYTE,
		data = outPixels[0],
		minFilter = gl.GL_NEAREST,
		magFilter = gl.GL_NEAREST,
		wrap = {
			s = gl.GL_CLAMP_TO_EDGE,
			t = gl.GL_CLAMP_TO_EDGE,
		},
	}
	require 'ffi.req' 'c.stdlib'	-- free()
	ffi.C.free(outPixels[0])	-- just betting here I have to free this myself ...
	ig.ImFontAtlas_SetTexID(self.fontAtlas, ffi.cast('ImTextureID', self.fontTex.id))
--]]

	-- load config if it exists
	xpcall(function()
		self.cfg = fromlua(assert(path(self.cfgfilename):read()))
	end, function(err)
		print("failed to read config file: "..tostring(err))
	end)
	self.cfg = self.cfg or {}

	-- load high scores if it exists
	xpcall(function()
		self.highscores = fromlua(assert(path(self.highScoresFilename):read()))
	end, function(err)
		print("failed to read config file: "..tostring(err))
	end)
	self.highscores = self.highscores or {}

	-- board size is 80 x 144 visible
	-- piece is 4 blocks arranged
	-- blocks are 8 x 8 by default
	self.pieceSizeInBlocks = vec2i(4,4)	-- fixed

	--self.cfg.voxelsPerBlock = self.cfg.voxelsPerBlock or 8	-- original
	self.cfg.voxelsPerBlock = self.cfg.voxelsPerBlock or 16	-- double
	--self.cfg.voxelsPerBlock = self.cfg.voxelsPerBlock or 32		-- quadruple

	self.cfg.effectVolume = self.cfg.effectVolume or 1
	self.cfg.backgroundVolume = self.cfg.backgroundVolume or .3
	self.cfg.startLevel = self.cfg.startLevel or 1
	self.cfg.movedx = self.cfg.movedx or 1				-- TODO configurable
	self.cfg.dropSpeed = self.cfg.dropSpeed or 5
	self.cfg.sandModel = self.cfg.sandModel or 1
	self.cfg.speedupCoeff = self.cfg.speedupCoeff or .007
	self.cfg.toppleChance = self.cfg.toppleChance or 1
	self.cfg.playerKeys = self.cfg.playerKeys or {}
	self.cfg.numColors = self.cfg.numColors or 4
	self.cfg.screenButtonRadius = self.cfg.screenButtonRadius or .05
	if self.cfg.continuousDrop == nil then
		self.cfg.continuousDrop = true
	end
	if not self.cfg.colors then
		self.cfg.colors = {}
		for i,color in ipairs(self.defaultColors) do
			self.cfg.colors[i] = {table.unpack(color)}
		end
	end
	self.cfg.boardSizeInBlocks = self.cfg.boardSizeInBlocks or {x=10 , y=18}	-- original
	--self.cfg.boardSizeInBlocks = self.cfg.boardSizeInBlocks or {x=20, y=25}
	--self.cfg.boardSizeInBlocks = self.cfg.boardSizeInBlocks or {x=10, y=45}
	--self.cfg.boardSizeInBlocks = self.cfg.boardSizeInBlocks or {x=64, y=64}
	self.cfg.numNextPieces = self.cfg.numNextPieces or 3

	self.numPlayers = 1

	self.fps = 0
	self.numSandVoxels = 0

	self.loseScreenDuration = 3

	self.buttonTex = GLTex2D{
		image = Image'tex/button.png':flip(),
		wrap = {
			s = gl.GL_CLAMP_TO_EDGE,
			t = gl.GL_CLAMP_TO_EDGE,
		},
		minFilter = gl.GL_NEAREST,
		magFilter = gl.GL_LINEAR,
	}

	self.youloseTex = GLTex2D{
		image = Image'tex/youlose.png':flip(),
		wrap = {
			s = gl.GL_CLAMP_TO_EDGE,
			t = gl.GL_CLAMP_TO_EDGE,
		},
		minFilter = gl.GL_NEAREST,
		magFilter = gl.GL_NEAREST,
	}
	self.splashTex = GLTex2D{
		image = Image'tex/splash.png':flip(),
		wrap = {
			s = gl.GL_CLAMP_TO_EDGE,
			t = gl.GL_CLAMP_TO_EDGE,
		},
		minFilter = gl.GL_NEAREST,
		magFilter = gl.GL_NEAREST,
	}

	-- TODO use self.view with .useBuiltinMatrixMath=true
	self.projMat = matrix({4,4},'float'):zeros()
	self.mvMat = matrix({4,4},'float'):zeros()
	self.mvProjMat = matrix({4,4},'float'):zeros()

	local vtxbufCPU = ffi.new('float[8]', {
		0,0,
		1,0,
		0,1,
		1,1,
	})
	self.quadVertexBuf = GLArrayBuffer{
		size = ffi.sizeof(vtxbufCPU),
		data = vtxbufCPU,
	}:unbind()

	--self.glslVersion = 460	-- too new
	--self.glslVersion = 430
	--self.glslVersion = '320 es'	-- too new
	self.glslVersion = '300 es'
	self.shaderHeader =
'#version '..self.glslVersion..'\n'
..'precision highp float;\n'

	self.displayShader = GLProgram{
		vertexCode = self.shaderHeader..[[
in vec2 vertex;
out vec2 texcoordv;
uniform mat4 mvProjMat;
void main() {
	texcoordv = vertex;
	gl_Position = mvProjMat * vec4(vertex, 0., 1.);
}
]],
		fragmentCode = self.shaderHeader..[[
in vec2 texcoordv;
out vec4 fragColor;
uniform sampler2D tex;
uniform bool useAlphaTest;
void main() {
	fragColor = texture(tex, texcoordv);
	if (useAlphaTest && fragColor.a == 0.) discard;
}
]],
		uniforms = {
			tex = 0,
			useAlphaTest = false,
		},

		attrs = {
			vertex = self.quadVertexBuf,
		},
	}:useNone()

	self.populatePieceShader = GLProgram{
		vertexCode = self.shaderHeader..[[
in vec2 vertex;
out vec2 texcoordv;
uniform mat4 mvProjMat;
void main() {
	texcoordv = vertex;
	gl_Position = mvProjMat * vec4(vertex, 0., 1.);
}
]],
		fragmentCode = self.shaderHeader..[[
in vec2 texcoordv;
out vec4 fragColor;

uniform sampler2D tex;
uniform sampler2D randtex;
uniform vec4 color;
uniform vec3 pieceSize;	//.z = voxelsPerBlock

void main() {
	vec4 dstc = texture(tex, texcoordv) * color;
	vec2 ij = texcoordv * pieceSize.xy;
	float voxelsPerBlock = pieceSize.z;
	vec2 uv = mod(ij, voxelsPerBlock );
	float c = max(
		abs(uv.x - voxelsPerBlock*.5),
		abs(uv.y - voxelsPerBlock*.5)
	) / (voxelsPerBlock*.5);
	float l = texture(randtex, texcoordv).r * .25 + .75;
	l *= .25 + .75 * sqrt(1. - c*c);
	fragColor = vec4(dstc.xyz * l, dstc.w);
}
]],
		uniforms = {
			tex = 0,
			randtex = 1,
		},

		attrs = {
			vertex = self.quadVertexBuf,
		},
	}:useNone()

	self.updatePieceOutlineShader = GLProgram{
		vertexCode = self.shaderHeader..[[
in vec2 vertex;
out vec2 texcoordv;
uniform mat4 mvProjMat;
void main() {
	texcoordv = vertex;
	gl_Position = mvProjMat * vec4(vertex, 0., 1.);
}
]],
		fragmentCode = self.shaderHeader..[[
in vec2 texcoordv;
out vec4 fragColor;

uniform sampler2D pieceTex;
uniform ivec2 pieceSize;
uniform ivec3 pieceOutlineSize;	//.z = pieceOutlineRadius;
uniform vec3 color;

float lenSq(vec2 v) {
	return dot(v,v);
}

void main() {
	float maxDistSq = float(pieceOutlineSize.x + pieceOutlineSize.y);
	float bestDistSq = maxDistSq;

	int pieceOutlineRadius = pieceOutlineSize.z;
	ivec2 ij = ivec2(texcoordv * vec2(pieceOutlineSize));
	ivec2 ofs;
	for (ofs.y = -pieceOutlineRadius; ofs.y <= pieceOutlineRadius; ++ofs.y) {
		for (ofs.x = -pieceOutlineRadius; ofs.x <= pieceOutlineRadius; ++ofs.x) {
			ivec2 xy = ij - pieceOutlineRadius + ofs;
			if (xy.x >= 0 && xy.x < pieceSize.x &&
				xy.y >= 0 && xy.y < pieceSize.y
			) {
				vec4 c = texelFetch(pieceTex, xy, 0);
				if (c != vec4(0.)) {
					float distSq = max(1., lenSq(vec2(ofs)));
					bestDistSq = min(bestDistSq, distSq);
				}
			}
		}
	}

	if (bestDistSq < maxDistSq) {
		float frac = 1. / bestDistSq;
		fragColor = vec4(color * frac, 1.);
	} else {
		fragColor = vec4(0.);
	}
}
]],
		uniforms = {
			pieceTex = 0,
		},

		attrs = {
			vertex = self.quadVertexBuf,
		},

	}

	self.sounds = {}

	if self.useAudio then
		xpcall(function()
			self.audio = Audio()
			self.audioSources = table()
			self.audioSourceIndex = 0
			self.audio:setDistanceModel'linear clamped'
			for i=1,31 do	-- 31 for DirectSound, 32 for iphone, infinite for all else?
				local src = AudioSource()
				src:setReferenceDistance(1)
				src:setMaxDistance(self.maxAudioDist)
				src:setRolloffFactor(1)
				self.audioSources[i] = src
			end

			self.bgMusicFiles = table{
				'music/Desert-City.ogg',
				'music/Exotic-Plains.ogg',
				'music/Ibn-Al-Noor.ogg',
				'music/Market_Day.ogg',
				'music/Return-of-the-Mummy.ogg',
				'music/temple-of-endless-sands.ogg',
				'music/wombat-noises-audio-the-legend-of-narmer.ogg',
			}
			self.bgMusicFileName = self.bgMusicFiles:pickRandom()
			if self.bgMusicFileName then
				self.bgMusic = self:loadSound(self.bgMusicFileName)
				self.bgAudioSource = AudioSource()
				self.bgAudioSource:setBuffer(self.bgMusic)
				self.bgAudioSource:setLooping(true)
				self.bgAudioSource:setGain(self.cfg.backgroundVolume)
				self.bgAudioSource:play()
			end
		end, function(err)
			print(err..'\n'..debug.traceback())
			self.audio = nil
			self.useAudio = false	-- or just test audio's existence?
		end)
	end

	local SplashScreenState = require 'sand-attack.menustate.splashscreen'
	self.menustate = SplashScreenState(self)

	-- initial reset
	-- needed for a few things that i'm too lazy to change
	-- so i guess i could play a demo in the background when the game starts
	-- like so many other games
	self:reset{
		-- me being lazy about restructuring
		dontRecordOrPlay = true,
	}

	glreport'here'
end

function App:makeTexFromImage(img)
	local tex = GLTex2D{
		internalFormat = gl.GL_RGBA,
		width = tonumber(img.width),
		height = tonumber(img.height),
		format = gl.GL_RGBA,
		type = gl.GL_UNSIGNED_BYTE,
		wrap = {
			s = gl.GL_CLAMP_TO_EDGE,
			t = gl.GL_CLAMP_TO_EDGE,
		},
		minFilter = gl.GL_NEAREST,
		magFilter = gl.GL_NEAREST,
		data = img.buffer,	-- stored
	}
		:unbind()
	tex.image = img
	return tex
end

-- static method
function App:makeTexWithBlankImage(size)
	local img = Image(size.x, size.y, 4, 'unsigned char')
	ffi.fill(img.buffer, 4 * size.x * size.y)
	return self:makeTexFromImage(img)
end

function App:makePieceImage(s)
	s = string.split(s, '\n')
	local img = Image(self.pieceSize.x, self.pieceSize.y, 4, 'unsigned char')
	local ptr = ffi.cast('uint32_t*', img.buffer)
	ffi.fill(ptr, 4 * img.width * img.height)
	for j=0,self.pieceSizeInBlocks.y-1 do
		for i=0,self.pieceSizeInBlocks.x-1 do
			if s[j+1]:sub(i+1,i+1) == '#' then
				for u=0,self.cfg.voxelsPerBlock-1 do
					for v=0,self.cfg.voxelsPerBlock-1 do
						ptr[(u + self.cfg.voxelsPerBlock * i) + img.width * (v + self.cfg.voxelsPerBlock * j)] = 0xffffffff
					end
				end
			end
		end
	end
	return self:makeTexFromImage(img)
end

function App:loadSound(filename)
	if not filename then error("warning: couldn't find sound file "..searchfilename) end
	local sound = self.sounds[filename]
	if not sound then
		sound = AudioBuffer(filename)
		self.sounds[filename] = sound
	end
	return sound
end

function App:getNextAudioSource()
	if #self.audioSources == 0 then return end
	local startIndex = self.audioSourceIndex
	repeat
		self.audioSourceIndex = self.audioSourceIndex % #self.audioSources + 1
		local source = self.audioSources[self.audioSourceIndex]
		if not source:isPlaying() then
			return source
		end
	until self.audioSourceIndex == startIndex
end

function App:playSound(name, volume, pitch)
	if not self.useAudio then return end
	local source = self:getNextAudioSource()
	if not source then
		print('all audio sources used')
		return
	end

	local sound = self:loadSound(name)
	source:setBuffer(sound)
	source.volume = volume	-- save for later
	source:setGain((volume or 1) * self.cfg.effectVolume)
	source:setPitch(pitch or 1)
	source:setPosition(0, 0, 0)
	source:setVelocity(0, 0, 0)
	source:play()

	return source
end

function App:saveConfig()
	path(self.cfgfilename):write(tolua(self.cfg))
end

function App:saveHighScores()
	path(self.highScoresFilename):write(tolua(self.highscores))
end

function App:updateGameScale()
	self.cfg.voxelsPerBlock = math.max(1, self.cfg.voxelsPerBlock)
	self.gameScaleFloat = self.cfg.voxelsPerBlock / 8
	self.gameScale = math.ceil(self.gameScaleFloat)
	self.updatesPerFrame = self.gameScale
end

function App:reset(args)
	args = args or {}

	self:saveConfig()
	self:updateGameScale()

	self.recordingDemo = nil
	self.playingDemo = nil

	if not args.dontRecordOrPlay then
		if args.playingDemo then
			xpcall(function()
				self.playingDemo = setmetatable(
					assert(fromlua(
						assert(path(args.playingDemo):read())
					)),
					table
				)
				self.rng = RNG(self.playingDemo.seed)
			end, function(err)
				print('failed to load demo: '..tostring(err))
				-- for getting more info
				--print(err..'\n'..debug.traceback())
			end)
		end
		if not self.playingDemo then
			local randseed = os.time()
			self.rng = RNG(randseed)
			self.recordingDemo = table{
				seed = randseed,
			}
		end
	else
		local randseed = os.time()
		self.rng = RNG(randseed)
	end


	-- init pieces

	self.pieceSize = self.pieceSizeInBlocks * self.cfg.voxelsPerBlock

	self.pieceFBO = GLFBO{width=self.pieceSize.x, height=self.pieceSize.y}
		:unbind()

	self.pieceOutlineSize = self.pieceSize + 2 * self.pieceOutlineRadius
	self.pieceOutlineFBO = GLFBO{width=self.pieceOutlineSize.x, height=self.pieceOutlineSize.y}
		:unbind()

	do
		local size = self.pieceSize
		local img = Image(size.x, size.y, 4, 'unsigned char')
		local ptr = ffi.cast('uint32_t*', img.buffer)
		for j=0,size.y-1 do
			for i=0,size.x-1 do
				ptr[0] = bit.bor(
					self.rng(0,255),
					bit.lshift(self.rng(0,255), 8),
					bit.lshift(self.rng(0,255), 16),
					bit.lshift(self.rng(0,255), 24)
				)
				ptr = ptr + 1
			end
		end
		self.pieceRandomColorTex = self:makeTexFromImage(img)
	end


	self.pieceSourceTexs = table{
		self:makePieceImage[[
 #
 #
 #
 #
]],
		self:makePieceImage[[
 #
 #
 ##
]],
		self:makePieceImage[[
   #
   #
  ##
]],
		self:makePieceImage[[

 ##
 ##
]],
		self:makePieceImage[[

 #
###
]],
		self:makePieceImage[[
 #
 ##
  #
]],
		self:makePieceImage[[
  #
 ##
 #
]],
	}


	-- init board


	self.sandSize = vec2i(
		self.cfg.boardSizeInBlocks.x * self.cfg.voxelsPerBlock,
		self.cfg.boardSizeInBlocks.y * self.cfg.voxelsPerBlock)
	local w, h = self.sandSize:unpack()

	self.loseTime = nil

	local sandModelClass = assert(sandModelClasses[self.cfg.sandModel])
	self.sandmodel = sandModelClass(self)

	-- I only really need to recreate the sand & flash texs if the board size changes ...
	self.flashTex = self:makeTexWithBlankImage(self.sandSize)

	-- and I only really need to recreate these if the piece size changes ...
	self.rotPieceTex = self:makeTexWithBlankImage(self.pieceSize)
	self.nextPieces = range(self.cfg.numNextPieces):mapi(function(i)
		local tex = self:makeTexWithBlankImage(self.pieceSize)
		return {tex=tex}
	end)


	self.sandmodel:reset()

	self.gameColors = table.sub(self.cfg.colors, 1, self.cfg.numColors):mapi(function(c) return vec3f(c) end)		-- colors used now
	assert(#self.gameColors == self.cfg.numColors)	-- menu system should handle this

	self.players = range(self.numPlayers):mapi(function(i)
		return Player{index=i, app=self}
	end)

	-- populate the nextpieces via rotation
	for i=1,#self.nextPieces do
		self:newPiece(self.players[1])
	end
	-- populate the players pieces
	for _,player in ipairs(self.players) do
		self:newPiece(player)
	end

	self.lastUpdateTime = getTime()
	self.gameTime = 0
	self.gameTick = ffi.new('uint64_t', 0)
	self.fallTick = 0
	self.lastLineTime = -math.huge
	self.score = 0
	self.lines = 0
	self.level = self.cfg.startLevel
	self.scoreChain = 0
	self:upateFallSpeed()
	self.paused = true

-- debugging:
--self.sandmodel:test()
end

function App:upateFallSpeed()
	-- https://harddrop.com/wiki/Tetris_Worlds
	local maxSpeedLevel = 13 -- fastest level .. no faster is permitted
	local effectiveLevel = math.min(self.level, maxSpeedLevel)
	-- TODO make this curve customizable
	local secondsPerRow = (.8 - ((effectiveLevel-1.)*self.cfg.speedupCoeff))^(effectiveLevel-1.)
	local secondsPerLine = secondsPerRow / self.cfg.voxelsPerBlock
	-- how many ticks to wait before dropping a piece
	self.ticksToFall = secondsPerLine / self.updateInterval
--print('effectiveLevel', effectiveLevel, 'secondsPerRow', secondsPerRow, 'scondsPerLin', secondsPerLine, 'ticksToFall', self.ticksToFall)
end

-- fill in a new piece texture
-- generate it based on the piece template
function App:populatePiece(args)
	local srctex = self.pieceSourceTexs:pickRandom()
	local colorIndex = self.rng(#self.gameColors)	-- 1..n for n colors
	local color = self.gameColors[colorIndex]
	local alpha = colorIndex/#self.gameColors		-- [1/n, 1]

	local fbo = self.pieceFBO
	local dsttex = args.tex
	local shader = self.populatePieceShader

	gl.glViewport(0, 0, self.pieceSize.x, self.pieceSize.y)

	fbo:bind()
		:setColorAttachmentTex2D(dsttex.id)
	local res, err = fbo.check()
	if not res then print(err) end

	shader
		:use()
		:enableAttrs()

	self.mvProjMat:setOrtho(0, 1, 0, 1, -1, 1)
	gl.glUniformMatrix4fv(
		shader.uniforms.mvProjMat.loc,
		1,
		gl.GL_FALSE,
		self.mvProjMat.ptr)
	gl.glUniform4f(shader.uniforms.color.loc, color.x, color.y, color.z, alpha)
	gl.glUniform3f(shader.uniforms.pieceSize.loc,
		self.pieceSize.x,
		self.pieceSize.y,
		self.cfg.voxelsPerBlock)

	srctex:bind(0)
	self.pieceRandomColorTex:bind(1)

	gl.glDrawArrays(gl.GL_TRIANGLE_STRIP, 0, 4)

	self.pieceRandomColorTex:unbind(1)
	srctex:unbind(0)

	shader
		:disableAttrs()
		:useNone()

	gl.glReadPixels(
		0,						--GLint x,
		0,						--GLint y,
		self.pieceSize.x,		--GLsizei width,
		self.pieceSize.y,		--GLsizei height,
		gl.GL_RGBA,				--GLenum format,
		gl.GL_UNSIGNED_BYTE,	--GLenum type,
		dsttex.image.buffer)	--void *pixels

	fbo:unbind()

	gl.glViewport(0, 0, self.width, self.height)
end

function App:newPiece(player)
	local w, h = self.sandSize:unpack()

	local lastPiece = self.nextPieces:last()
	-- cycle pieces
	do
		local tex = player.pieceTex
		local np1 = self.nextPieces[1]
		player.pieceTex = np1.tex
		for i=1,#self.nextPieces-1 do
			local np = self.nextPieces[i]
			local np2 = self.nextPieces[i+1]
			np.tex = np2.tex
		end
		lastPiece.tex = tex
	end
	self:populatePiece(lastPiece)
	--]]

	self:updatePieceTex(player)
	player.piecePos = vec2f((w-self.pieceSize.x)*.5, h-1)
	player.piecePosLast = vec2f(player.piecePos)
	if self.sandmodel:testPieceMerge(player) then
		-- but this means you can pause mid-losing ... meh
		self.loseTime = self.thisTime
	end
end

local function vec3fto4ub(v)
	return bit.bor(
		math.floor(math.clamp(v.x, 0, 1) * 255),
		bit.lshift(math.floor(math.clamp(v.y, 0, 1) * 255), 8),
		bit.lshift(math.floor(math.clamp(v.z, 0, 1) * 255), 16),
		0xff000000
	)
end

-- called by new piece tex, and after rotating the pice
App.pieceOutlineRadius = 5
function App:updatePieceTex(player)
	-- while we're here, find the first and last cols with content
	-- use this for testing screen bounds
	local pieceBuf = ffi.cast('uint32_t*', player.pieceTex.image.buffer)
	for _,info in ipairs{
		{0,self.pieceSize.x-1,1, 'pieceColMin'},
		{self.pieceSize.x-1,0,-1, 'pieceColMax'},
	} do
		local istart, iend, istep, ifield = table.unpack(info)
		for i=istart,iend,istep do
			local found
			for j=0,self.pieceSize.y-1 do
				if pieceBuf[i + self.pieceSize.x * j] ~= 0 then
					found = true
					break
				end
			end
			if found then
				player[ifield] = i
				break
			end
		end
	end

	-- same thing with rows to determine max row, to determine when we hit th ground
	for _,info in ipairs{
		{0,self.pieceSize.y-1,1, 'pieceRowMin'},
		{self.pieceSize.y-1,0,-1, 'pieceRowMax'},
	} do
		local jstart, jend, jstep, jfield = table.unpack(info)
		for j=jstart,jend,jstep do
			local found
			for i=0,self.pieceSize.x-1 do
				if pieceBuf[i + self.pieceSize.x * j] ~= 0 then
					found = true
					break
				end
			end
			if found then
				player[jfield] = j
				break
			end
		end
	end

	-- [[ update the piece outline
	local fbo = self.pieceOutlineFBO
	local dsttex = player.pieceOutlineTex
	local shader = self.updatePieceOutlineShader
	local srctex = player.pieceTex

	gl.glViewport(0, 0, fbo.width, fbo.height)

	fbo:bind()
		:setColorAttachmentTex2D(dsttex.id)
	local res, err = fbo.check()
	if not res then print(err) end

	shader:use()
		:enableAttrs()

	self.mvProjMat:setOrtho(0, 1, 0, 1, -1, 1)
	gl.glUniformMatrix4fv(
		shader.uniforms.mvProjMat.loc,
		1,
		gl.GL_FALSE,
		self.mvProjMat.ptr)
	gl.glUniform2i(shader.uniforms.pieceSize.loc,
		self.pieceSize.x,
		self.pieceSize.y)
	gl.glUniform3i(shader.uniforms.pieceOutlineSize.loc,
		self.pieceOutlineSize.x,
		self.pieceOutlineSize.y,
		self.pieceOutlineRadius)
	gl.glUniform3f(shader.uniforms.color.loc, player.color:unpack())

	srctex:bind()
	gl.glDrawArrays(gl.GL_TRIANGLE_STRIP, 0, 4)
	srctex:unbind()

	shader:disableAttrs()
		:useNone()

	fbo:unbind()

	gl.glViewport(0, 0, self.width, self.height)
	--]]
end

function App:rotatePiece(player)
	if not player.pieceTex then return end

	local fbo = self.pieceFBO
	local srctex = player.pieceTex
	local dsttex = self.rotPieceTex
	local shader = self.displayShader
	gl.glViewport(0, 0, self.pieceSize.x, self.pieceSize.y)

	fbo:bind()
		:setColorAttachmentTex2D(dsttex.id)
	local res, err = fbo.check()
	if not res then print(err) end

	shader
		:use()
		:enableAttrs()

	self.projMat:setOrtho(0, 1, 0, 1, -1, 1)
	self.mvMat
		:setTranslate(.5, .5, 0)
		:applyRotate(90, 0, 0, 1)
		:applyTranslate(-.5, -.5, 0)
	self.mvProjMat:mul4x4(self.projMat, self.mvMat)
	gl.glUniformMatrix4fv(
		shader.uniforms.mvProjMat.loc,
		1,
		gl.GL_FALSE,
		self.mvProjMat.ptr)
	gl.glUniform1i(shader.uniforms.useAlphaTest.loc, 0)

	srctex:bind()
	gl.glDrawArrays(gl.GL_TRIANGLE_STRIP, 0, 4)
	srctex:unbind()

	shader
		:disableAttrs()
		:useNone()

	-- still needed by
	-- 	- App:updatePieceTex for calculating pieceColMin and pieceColMax
	--	- SandModel:testPieceMerge and SandModel:mergePiece
	gl.glReadPixels(
		0,						--GLint x,
		0,						--GLint y,
		self.pieceSize.x,		--GLsizei width,
		self.pieceSize.y,		--GLsizei height,
		gl.GL_RGBA,				--GLenum format,
		gl.GL_UNSIGNED_BYTE,	--GLenum type,
		dsttex.image.buffer)	--void *pixels

	fbo:unbind()

	gl.glViewport(0, 0, self.width, self.height)

	player.pieceTex, self.rotPieceTex = self.rotPieceTex, player.pieceTex

	self:updatePieceTex(player)
	self:constrainPiecePos(player)
end

function App:constrainPiecePos(player)
	-- TODO check blit and don't move if any pixels are oob
	local w, h = self.sandSize:unpack()
	if player.piecePos.x < -player.pieceColMin then player.piecePos.x = -player.pieceColMin end
	if player.piecePos.x > w-1-player.pieceColMax then
		player.piecePos.x = w-1-player.pieceColMax
	end
end

local vtxs = {
	{0,0},
	{1,0},
	{1,1},
	{0,1},
}

function App:updateGame()
	local w, h = self.sandSize:unpack()
	local dt = self.thisTime - self.lastUpdateTime
	if dt <= self.updateInterval then return end
	dt = self.updateInterval

	--[[ fast-forward to catch up? messes up with pause too
	self.lastUpdateTime = self.lastUpdateTime + self.updateInterval
	--]]
	-- [[ stutter
	self.lastUpdateTime = self.thisTime
	--]]
	self.gameTime = self.gameTime + self.updateInterval
	self.gameTick = self.gameTick + 1

	local sandmodel = self.sandmodel
	local needsCheckLine = sandmodel:update()

	for _,player in ipairs(self.players) do
		player.piecePosLast:set(player.piecePos:unpack())
	end

	-- [[ hack for testing RNG
	-- soon this'll drive demo input :

	if self.recordingDemo then
		local event
		for playerIndex,player in ipairs(self.players) do
			for _,k in ipairs(player.gameKeyNames) do
				if player.keyPress[k] ~= player.keyPressLast[k] then
					event = event or {t=self.gameTick}
					event[playerIndex..k] = player.keyPress[k]
				end
			end
		end
		self.recordingDemo:insert(event)
	elseif self.playingDemo then
		local event = self.playingDemo[1]
		if event and event.t == self.gameTick then
			self.playingDemo:remove(1)
		else
			event = nil
		end
		if event then
			for playerIndex,player in ipairs(self.players) do
				for _,k in ipairs(player.gameKeyNames) do
					local v = event[playerIndex..k]
					if v ~= nil then
						player.keyPress[k] = v
					end
				end
			end
		end
	end

	-- now draw the shape over the sand
	-- test piece for collision with sand
	-- if it collides then merge it
	for _,player in ipairs(self.players) do
		-- TODO key updates at higher interval than drop rate ...
		-- but test collision for both
		-- TODO tap to move vs hold to move ... just like with dropping?  nah cuz that is still hold-to-go-full-speed
		-- maybe something more like original tetris, push to go one block, hold past a delay to go full speed
		local dx = 0
		if player.keyPress.left then
			dx = dx - 1
		end
		if player.keyPress.right then
			dx = dx + 1
		end
		-- same as with dropSpeed...
		--player.piecePos.x = player.piecePos.x + dx * self.cfg.movedx * self.gameScale
		player.piecePos.x = player.piecePos.x + dx * self.cfg.movedx * self.gameScaleFloat
		self:constrainPiecePos(player)

		-- don't allow holding down through multiple drops ... ?
		if player.keyPress.down
		and not player.keyPressLast.down
		then
			player.droppingPiece = true
		end
		if not player.keyPress.down then
			player.droppingPiece = false
		end
		if player.droppingPiece then
			-- gameScale seems like a nice var at first, but it is integer based on pixels-per-block/8, so it's 1 for pixels-per-block ranging [1,8]
			--player.piecePos.y = player.piecePos.y - self.cfg.dropSpeed * self.gameScale
			-- so I want smaller resolution here...
			player.piecePos.y = player.piecePos.y - self.cfg.dropSpeed * self.gameScaleFloat
		end
		if player.keyPress.up and not player.keyPressLast.up then
			self:rotatePiece(player)
		end
		if player.keyPress.pause and not player.keyPressLast.pause then
			self.paused = true
		end
	end

	self.fallTick = self.fallTick + 1
	if self.fallTick >= self.ticksToFall then
		self.fallTick = 0
		local falldy = 1/self.ticksToFall
		for _,player in ipairs(self.players) do
			player.piecePos.y = player.piecePos.y - falldy
		end
	end

	for _,player in ipairs(self.players) do
		local merge
		if player.piecePos.y <= -self.pieceSize.y then
			player.piecePos.x = player.piecePosLast.x
			for y=-self.pieceSize.y,math.floor(player.piecePosLast.y) do
				player.piecePos.y = y
				if not sandmodel:testPieceMerge(player) then break end
			end
			merge = true
		else
			if sandmodel:testPieceMerge(player) then
				player.piecePos.x = player.piecePosLast.x
				for y=math.floor(player.piecePos.y)+1,math.floor(player.piecePosLast.y) do
					player.piecePos.y = y
					if not sandmodel:testPieceMerge(player) then break end
				end
				merge = true
			end
		end
		if merge then
			self:playSound'sfx/place.wav'
			if not self.cfg.continuousDrop then
				player.droppingPiece = false	-- stop dropping piece
			end

			sandmodel:mergePiece(player)
			needsCheckLine = true

			-- piece Y + pieceRowMin is the row [0,h)
			-- so Y + pieceRowMax is the top ...
			-- so if that is ever >= h then we lose
			if player.piecePos.y + player.pieceRowMin >= h then
				self.loseTime = self.thisTime
			end

			self:newPiece(player)
		end
	end

	if not dontCheckForLinesEver then

		-- try to find a connection from left to right
		local anyCleared
		if needsCheckLine then
			local clearedCount = sandmodel:checkClearBlobs()
			if clearedCount ~= 0 then
				anyCleared = true

				if self.gameTime - self.lastLineTime < self.chainDuration then
					self.scoreChain = self.scoreChain + 1
				else
					self.scoreChain = 0
				end
				-- piece chain count, score multipliers, etc
				-- https://tetris.fandom.com/wiki/Scoring
				-- 2 => x2*5/4, 3 => x3*2*5/4, 4 => x4*3*2*5/4
				local modifier = self.scoreChain == 0 and 1 or math.factorial(self.scoreChain+1) * 5/4
	--print('scoreChain '..self.scoreChain, 'modifier', modifier)

				self.score = self.score + math.ceil(self.level * clearedCount * modifier)
				self.lines = self.lines + 1
				if self.lines % 10 == 0 then
					self.level = self.level + 1
					self:playSound'sfx/levelup.wav'
					self:upateFallSpeed()
				end

				self:playSound'sfx/line.wav'

				-- flashTex was filled in by sandmodel:clearBlob
				-- ... which is still on CPU
				self.flashTex:bind():subimage()
				self.lastLineTime = self.gameTime

				-- sph only
				if sandmodel.doneClearingBlobs then
					sandmodel:doneClearingBlobs()
				end
			end
		end
	end

	-- TODO for sand model automata-gpu,
	--  we don't need to update in case of 'needsCheckLine' alone
	if sandmodel.sandImageDirty then
		local sandTex = sandmodel:getSandTex()
		sandTex:bind():subimage()
		sandmodel.sandImageDirty = false
	end

	for _,player in ipairs(self.players) do
		for k,v in pairs(player.keyPress) do
			player.keyPressLast[k] = v
		end
	end
end

function App:update(...)
	self.thisTime = getTime()

	gl.glClearColor(.5, .5, .5, 1)
	gl.glClear(gl.GL_COLOR_BUFFER_BIT)

	local w, h = self.sandSize:unpack()
	local sandmodel = self.sandmodel

	if not self.paused then
		-- if we haven't lost yet ...
		if not self.loseTime then
			self:updateGame()
		end

		--[[ pouring sand
		self.sandCPU[bit.rshift(w,1) + w * (h - 1)] = bit.bor(
			self.rng(0,16777215),
			0xff000000,
		)
		--]]

		-- draw

		local aspectRatio = self.width / self.height
		local s = w / h

		local shader = self.displayShader

		self.projMat:setOrtho(-.5 * aspectRatio, .5 * aspectRatio, -.5, .5, -1, 1)
		shader:use()
			:enableAttrs()

		self.mvMat:setTranslate(-.5 * s, -.5)
			:applyScale(s, 1)
		self.mvProjMat:mul4x4(self.projMat, self.mvMat)
		gl.glUniformMatrix4fv(shader.uniforms.mvProjMat.loc, 1, gl.GL_FALSE, self.mvProjMat.ptr)

		gl.glUniform1i(shader.uniforms.useAlphaTest.loc, 0)

		--[[ transparent for the background for sand area?
		gl.glEnable(gl.GL_ALPHA_TEST)
		--]]

		sandmodel:getSandTex():bind()
		gl.glDrawArrays(gl.GL_TRIANGLE_STRIP, 0, 4)

		--[[ transparent for the background for sand area?
		gl.glDisable(gl.GL_ALPHA_TEST)
		--]]

		-- draw the current piece
		for _,player in ipairs(self.players) do
			-- draw outline for multiplayer
			if self.numPlayers > 1 then
				self.mvMat:setTranslate(
						((math.floor(player.piecePos.x) - self.pieceOutlineRadius) / w - .5) * s,
						(math.floor(player.piecePos.y) - self.pieceOutlineRadius) / h - .5
					)
					:applyScale(
						(self.pieceSize.x + 2 * self.pieceOutlineRadius) / w * s,
						(self.pieceSize.y + 2 * self.pieceOutlineRadius) / h)
				self.mvProjMat:mul4x4(self.projMat, self.mvMat)
				gl.glUniformMatrix4fv(shader.uniforms.mvProjMat.loc, 1, gl.GL_FALSE, self.mvProjMat.ptr)

				gl.glEnable(gl.GL_BLEND)
				gl.glBlendFunc(gl.GL_SRC_ALPHA, gl.GL_ONE)

				player.pieceOutlineTex:bind()
				gl.glDrawArrays(gl.GL_TRIANGLE_STRIP, 0, 4)

				gl.glDisable(gl.GL_BLEND)
			end

			-- draw piece

			self.mvMat:setTranslate(
					(math.floor(player.piecePos.x) / w - .5) * s,
					math.floor(player.piecePos.y) / h - .5
				)
				:applyScale(self.pieceSize.x / w * s, self.pieceSize.y / h)
			self.mvProjMat:mul4x4(self.projMat, self.mvMat)
			gl.glUniformMatrix4fv(shader.uniforms.mvProjMat.loc, 1, gl.GL_FALSE, self.mvProjMat.ptr)

			gl.glUniform1i(shader.uniforms.useAlphaTest.loc, 1)
			player.pieceTex:bind()
			gl.glDrawArrays(gl.GL_TRIANGLE_STRIP, 0, 4)

			gl.glUniform1i(shader.uniforms.useAlphaTest.loc, 0)
		end

		-- draw flashing background if necessary
		local flashDt = self.gameTime - self.lastLineTime
		if flashDt < self.lineFlashDuration then
			self.wasFlashing = true
			gl.glUniform1i(shader.uniforms.useAlphaTest.loc, 1)
			local flashInt = bit.band(math.floor(flashDt * self.lineNumFlashes * 2), 1) == 0
			if flashInt then
				self.mvMat
					:setTranslate(-.5 * s, -.5)
					:applyScale(s, 1)
				self.mvProjMat:mul4x4(self.projMat, self.mvMat)
				gl.glUniformMatrix4fv(shader.uniforms.mvProjMat.loc, 1, gl.GL_FALSE, self.mvProjMat.ptr)

				self.flashTex:bind()
				gl.glDrawArrays(gl.GL_TRIANGLE_STRIP, 0, 4)
			end
			gl.glUniform1i(shader.uniforms.useAlphaTest.loc, 0)
		elseif self.wasFlashing then
			-- clear once we're done flashing
			self.wasFlashing = false

			local dsttex = self.flashTex
			local fbo = sandmodel.fbo

			gl.glViewport(0, 0, w, h)
			fbo:bind()
				:setColorAttachmentTex2D(dsttex.id)
			local res, err = fbo.check()
			if not res then print(err) end

			gl.glClearColor(0, 0, 0, 0)
			gl.glClear(gl.GL_COLOR_BUFFER_BIT)

			gl.glReadPixels(
				0,						--GLint x,
				0,						--GLint y,
				w,						--GLsizei width,
				h,						--GLsizei height,
				gl.GL_RGBA,				--GLenum format,
				gl.GL_UNSIGNED_BYTE,	--GLenum type,
				dsttex.image.buffer)	--void *pixels

			fbo:unbind()
			gl.glViewport(0, 0, self.width, self.height)
		end

		if self.loseTime then
			local loseDuration = self.thisTime - self.loseTime
			if math.floor(loseDuration * 2) % 2 == 0 then
				self.mvMat
					:setTranslate(-.5 * s, -.5)
					:applyScale(s, 1)
				self.mvProjMat:mul4x4(self.projMat, self.mvMat)
				gl.glUniformMatrix4fv(shader.uniforms.mvProjMat.loc, 1, gl.GL_FALSE, self.mvProjMat.ptr)

				gl.glUniform1i(shader.uniforms.useAlphaTest.loc, 1)
				self.youloseTex:bind()
				gl.glDrawArrays(gl.GL_TRIANGLE_STRIP, 0, 4)
				gl.glUniform1i(shader.uniforms.useAlphaTest.loc, 0)
			end
		end

		local nextPieceSize = .1
		for i=#self.nextPieces,1,-1 do
			local it = self.nextPieces[i]
			local dy = #self.nextPieces == 1 and 0 or (1 - nextPieceSize)/(#self.nextPieces-1)
			dy = math.min(dy, nextPieceSize * 1.1)

			self.mvMat
				:setTranslate(aspectRatio * .5 - nextPieceSize, .5 - (i-1) * dy)
				:applyScale(nextPieceSize, -nextPieceSize)
			self.mvProjMat:mul4x4(self.projMat, self.mvMat)
			gl.glUniformMatrix4fv(shader.uniforms.mvProjMat.loc, 1, gl.GL_FALSE, self.mvProjMat.ptr)

			it.tex:bind()
			gl.glDrawArrays(gl.GL_TRIANGLE_STRIP, 0, 4)
		end

		GLTex2D:unbind()
		shader
			:disableAttrs()
			:useNone()
	end

	if self.loseTime and self.thisTime - self.loseTime > self.loseScreenDuration then
		-- TODO same for 'End Time'
		-- TODO maybe go to a high score screen instead?
		self.loseTime = nil
		self.paused = true

		if self.playingDemo then
			self.playingDemo = nil
			local MainMenuState = require 'sand-attack.menustate.main'
			self.menustate = MainMenuState(self, true)
		else
			local HighScoreState = require 'sand-attack.menustate.highscore'
			self.menustate = HighScoreState(self, true)

			-- while we're here, write out the last key recording
			-- maybe in th future it'll go into the highscores data
			-- or maybe i'll compress it further meh
			-- Do this after opening the high-scores menu so that it has the option of doing something with this file?
			-- or maybe highscores overall will handle it?
			if self.recordingDemo then
				path'last-game-demo.lua':write(tolua(self.recordingDemo, {
					serializeForType = {
						cdata = function(state, x, tab, path, keyRef)
							return tostring(x)
						end,
					},
				}))
				self.recordingDemo = nil
			end
		end
	end

	-- update GUI
	App.super.update(self, ...)
	glreport'here'


	-- draw menustate over gui?
	-- right now it's just the splash screen and the touch buttons
	if self.menustate.update then
		self.menustate:update()
	end

	if self.showFPS then
		self.fpsSampleCount = self.fpsSampleCount + 1
		if self.thisTime - self.lastFrameTime >= 1 then
			local deltaTime = self.thisTime - self.lastFrameTime
			self.fps = self.fpsSampleCount / deltaTime
print(self.fps)
			self.lastFrameTime = self.thisTime
			self.fpsSampleCount = 0
		end
	end
end
App.lastFrameTime = 0
App.fpsSampleCount = 0

function App:drawTouchRegions()
	local buttonRadius = self.width * self.cfg.screenButtonRadius

	local shader = self.displayShader

	gl.glEnable(gl.GL_BLEND)
	gl.glBlendFunc(gl.GL_SRC_ALPHA, gl.GL_ONE)
	shader
		:use()
		:enableAttrs()
	gl.glUniform1i(shader.uniforms.useAlphaTest.loc, 0)
	self.buttonTex:bind()
	self.projMat:setOrtho(0,self.width,self.height,0,-1,1)
	for i=1,self.numPlayers do
		for _,keyname in ipairs(Player.keyNames) do
			local e = self.cfg.playerKeys[i][keyname]
			if e	-- might not exist for new players >2 ...
			and (e[1] == sdl.SDL_MOUSEBUTTONDOWN
				or e[1] == sdl.SDL_FINGERDOWN
			) then
				local x = e[2] * self.width
				local y = e[3] * self.height
				self.mvMat:setTranslate(
					x-buttonRadius,
					y-buttonRadius)
					:applyScale(2*buttonRadius, 2*buttonRadius)
				self.mvProjMat:mul4x4(self.projMat, self.mvMat)
				gl.glUniformMatrix4fv(shader.uniforms.mvProjMat.loc, 1, gl.GL_FALSE, self.mvProjMat.ptr)
				gl.glDrawArrays(gl.GL_TRIANGLE_STRIP, 0, 4)
			end
		end
	end
	self.buttonTex:unbind()
	shader
		:disableAttrs()
		:useNone()
	gl.glDisable(gl.GL_BLEND)
end

function App:flipBoard()
	self.sandmodel:flipBoard()
end

-- static, used by gamestate and app
function App:getEventName(sdlEventID, a,b,c)
	if not a then return '?' end
	local function dir(d)
		local s = table()
		local ds = 'udlr'
		for i=1,4 do
			if 0 ~= bit.band(d,bit.lshift(1,i-1)) then
				s:insert(ds:sub(i,i))
			end
		end
		return s:concat()
	end
	local function key(k)
		return ffi.string(sdl.SDL_GetKeyName(k))
	end
	return template(({
		[sdl.SDL_JOYHATMOTION] = 'joy<?=a?> hat<?=b?> <?=dir(c)?>',
		[sdl.SDL_JOYAXISMOTION] = 'joy<?=a?> axis<?=b?> <?=c?>',
		[sdl.SDL_JOYBUTTONDOWN] = 'joy<?=a?> button<?=b?>',
		[sdl.SDL_CONTROLLERAXISMOTION] = 'gamepad<?=a?> axis<?=b?> <?=c?>',
		[sdl.SDL_CONTROLLERBUTTONDOWN] = 'gamepad<?=a?> button<?=b?>',
		[sdl.SDL_KEYDOWN] = 'key <?=key(a)?>',
		[sdl.SDL_MOUSEBUTTONDOWN] = 'mouse <?=c?> x<?=math.floor(a*100)?> y<?=math.floor(b*100)?>',
		[sdl.SDL_FINGERDOWN] = 'finger x<?=math.floor(a*100)?> y<?=math.floor(b*100)?>',
	})[sdlEventID], {
		a=a, b=b, c=c,
		dir=dir, key=key,
	})
end

function App:processButtonEvent(press, ...)
	local buttonRadius = self.width * self.cfg.screenButtonRadius

	-- TODO put the callback somewhere, not a global
	-- it's used by the New Game menu
	if self.waitingForEvent then
		if press then
			local ev = {...}
			ev.name = self:getEventName(...)
			self.waitingForEvent.callback(ev)
			self.waitingForEvent = nil
		end
	else
		local etype, ex, ey = ...
		local descLen = select('#', ...)
		for playerIndex, playerConfig in ipairs(self.cfg.playerKeys) do
			for buttonName, buttonDesc in pairs(playerConfig) do
				-- special case for mouse/touch, test within a distanc
				local match = descLen == #buttonDesc
				if match then
					local istart = 1
					-- special case for mouse/touch, click within radius ...
					if etype == sdl.SDL_MOUSEBUTTONDOWN
					or etype == sdl.SDL_FINGERDOWN
					then
						match = etype == buttonDesc[1]
						if match then
							local dx = (ex - buttonDesc[2]) * self.width
							local dy = (ey - buttonDesc[3]) * self.height
							if dx*dx + dy*dy >= buttonRadius*buttonRadius then
								match = false
							end
							-- skip the first 2 for values
							istart = 4
						end
					end
					if match then
						for i=istart,descLen do
							if select(i, ...) ~= buttonDesc[i] then
								match = false
								break
							end
						end
					end
				end
				if match then
					local player = self.players[playerIndex]
					if player
					and (
						not self.playingDemo
						or not Player.gameKeySet[buttonName]
					) then
						player.keyPress[buttonName] = press
					end
				end
			end
		end
	end
end

function App:event(e, ...)
	-- handle UI
	App.super.event(self, e, ...)
	-- TODO if ui handling then return

	if self.menustate.event then
		if self.menustate:event(e, ...) then return end
	end

	-- handle any kind of sdl button event
	if e.type == sdl.SDL_JOYHATMOTION then
		--if e.jhat.value ~= 0 then
			-- TODO make sure all hat value bits are cleared
			-- or keep track of press/release
			for i=0,3 do
				local dirbit = bit.lshift(1,i)
				local press = bit.band(dirbit, e.jhat.value) ~= 0
				self:processButtonEvent(press, sdl.SDL_JOYHATMOTION, e.jhat.which, e.jhat.hat, dirbit)
			end
			--[[
			if e.jhat.value == sdl.SDL_HAT_CENTERED then
				for i=0,3 do
					local dirbit = bit.lshift(1,i)
					self:processButtonEvent(false, sdl.SDL_JOYHATMOTION, e.jhat.which, e.jhat.hat, dirbit)
				end
			end
			--]]
		--end
	elseif e.type == sdl.SDL_JOYAXISMOTION then
		-- -1,0,1 depend on the axis press
		local lr = math.floor(3 * (tonumber(e.jaxis.value) + 32768) / 65536) - 1
		local press = lr ~= 0
		if not press then
			-- clear both left and right movement
			self:processButtonEvent(press, sdl.SDL_JOYAXISMOTION, e.jaxis.which, e.jaxis.axis, -1)
			self:processButtonEvent(press, sdl.SDL_JOYAXISMOTION, e.jaxis.which, e.jaxis.axis, 1)
		else
			-- set movement for the lr direction
			self:processButtonEvent(press, sdl.SDL_JOYAXISMOTION, e.jaxis.which, e.jaxis.axis, lr)
		end
	elseif e.type == sdl.SDL_JOYBUTTONDOWN or e.type == sdl.SDL_JOYBUTTONUP then
		-- e.jbutton.menustate is 0/1 for up/down, right?
		local press = e.type == sdl.SDL_JOYBUTTONDOWN
		self:processButtonEvent(press, sdl.SDL_JOYBUTTONDOWN, e.jbutton.which, e.jbutton.button)
	elseif e.type == sdl.SDL_CONTROLLERAXISMOTION then
		-- -1,0,1 depend on the axis press
		local lr = math.floor(3 * (tonumber(e.caxis.value) + 32768) / 65536) - 1
		local press = lr ~= 0
		if not press then
			-- clear both left and right movement
			self:processButtonEvent(press, sdl.SDL_CONTROLLERAXISMOTION, e.caxis.which, e.jaxis.axis, -1)
			self:processButtonEvent(press, sdl.SDL_CONTROLLERAXISMOTION, e.caxis.which, e.jaxis.axis, 1)
		else
			-- set movement for the lr direction
			self:processButtonEvent(press, sdl.SDL_CONTROLLERAXISMOTION, e.caxis.which, e.jaxis.axis, lr)
		end
	elseif e.type == sdl.SDL_CONTROLLERBUTTONDOWN or e.type == sdl.SDL_CONTROLLERBUTTONUP then
		local press = e.type == sdl.SDL_CONTROLLERBUTTONDOWN
		self:processButtonEvent(press, sdl.SDL_CONTROLLERBUTTONDOWN, e.cbutton.which, e.cbutton.button)
	elseif e.type == sdl.SDL_KEYDOWN or e.type == sdl.SDL_KEYUP then
		local press = e.type == sdl.SDL_KEYDOWN
		self:processButtonEvent(press, sdl.SDL_KEYDOWN, e.key.keysym.sym)
	elseif e.type == sdl.SDL_MOUSEBUTTONDOWN or e.type == sdl.SDL_MOUSEBUTTONUP then
		local press = e.type == sdl.SDL_MOUSEBUTTONDOWN
		self:processButtonEvent(press, sdl.SDL_MOUSEBUTTONDOWN, tonumber(e.button.x)/self.width, tonumber(e.button.y)/self.height, e.button.button)
	--elseif e.type == sdl.SDL_MOUSEWHEEL then
	-- how does sdl do mouse wheel events ...
	elseif e.type == sdl.SDL_FINGERDOWN or e.type == sdl.SDL_FINGERUP then
		local press = e.type == sdl.SDL_FINGERDOWN
		self:processButtonEvent(press, sdl.SDL_FINGERDOWN, e.tfinger.x, e.tfinger.y)
	end

	-- TODO how to incorporate this into the gameplay ...
	if e.type == sdl.SDL_KEYDOWN
	or e.type == sdl.SDL_KEYUP
	then
		local down = e.type == sdl.SDL_KEYDOWN
		if down and e.key.keysym.sym == ('f'):byte() then
			if down then self:flipBoard() end
		end
	end
end

function App:updateGUI()
	ig.igPushFont(self.font)
	if self.menustate.updateGUI then
		self.menustate:updateGUI()
	end
	ig.igPopFont()
end

function App:exit()
	if self.useAudio then
		self.audio:shutdown()
	end
	App.super.exit(self)
end

return App
