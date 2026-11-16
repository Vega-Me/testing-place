--[[
	unpack-place.luau — turn a .rbxl/.rbxlx into a Rojo project tree.

	Usage (from repo root):  lune run tools/unpack-place place.rbxl

	Rules:
	  * Scripts           -> .server.luau / .client.luau / .luau  (dir + init.* if they have children)
	  * Subtree w/o code  -> single binary .rbxm (keeps every property, mesh, attribute, tag)
	  * Container w/ code -> directory + init.meta.json (className, simple properties, attributes)
	  * Services          -> src/<Service>, service-level properties go into default.project.json
	  * Workspace.Terrain / Camera stay in place.rbxl (Rojo doesn't round-trip them)
]]

local fs = require("@lune/fs")
local process = require("@lune/process")
local roblox = require("@lune/roblox")
local serde = require("@lune/serde")

local placePath = process.args[1] or "place.rbxl"
local OUT = "src"

local SERVICES = {
	"Workspace", "Lighting", "ReplicatedFirst", "ReplicatedStorage", "ServerScriptService",
	"ServerStorage", "StarterGui", "StarterPack", "StarterPlayer", "SoundService", "Teams",
	"MaterialService",
}
local IGNORE_RBXM_SERVICES = { Workspace = true, Lighting = true, SoundService = true, MaterialService = true }
local SKIP_CHILD = { Workspace = { Terrain = true, Camera = true } }
local SKIP_PROPS = { Name = true, Parent = true, ClassName = true, Source = true, Archivable = true }

local db = roblox.getReflectionDatabase()
local warnings = {}
local stats = { scripts = 0, models = 0, dirs = 0 }

local function warn(msg)
	table.insert(warnings, msg)
end

local function isScript(inst)
	return inst:IsA("LuaSourceContainer")
end

local function hasCode(inst)
	if isScript(inst) then
		return true
	end
	for _, d in inst:GetDescendants() do
		if isScript(d) then
			return true
		end
	end
	return false
end

local function safeName(name)
	local s = name:gsub('[<>:"/\\|%?%*%c]', "_")
	if s ~= name then
		warn(`renamed "{name}" -> "{s}" (illegal filename chars)`)
	end
	return s
end

-- Convert a property value to Rojo's JSON property format. Returns nil if unsupported.
local function encode(v)
	local t = typeof(v)
	if t == "string" or t == "boolean" then
		return v
	elseif t == "number" then
		return if v ~= v or v == math.huge or v == -math.huge then nil else v
	elseif t == "Vector3" then
		return { Vector3 = { v.X, v.Y, v.Z } }
	elseif t == "Vector2" then
		return { Vector2 = { v.X, v.Y } }
	elseif t == "Color3" then
		return { Color3 = { v.R, v.G, v.B } }
	elseif t == "UDim" then
		return { UDim = { v.Scale, v.Offset } }
	elseif t == "UDim2" then
		return { UDim2 = { { v.X.Scale, v.X.Offset }, { v.Y.Scale, v.Y.Offset } } }
	elseif t == "EnumItem" then
		return { Enum = v.Value }
	elseif t == "BrickColor" then
		return { BrickColor = v.Number }
	elseif t == "NumberRange" then
		return { NumberRange = { v.Min, v.Max } }
	elseif t == "CFrame" then
		local x, y, z, r00, r01, r02, r10, r11, r12, r20, r21, r22 = v:GetComponents()
		return { CFrame = { position = { x, y, z }, orientation = { { r00, r01, r02 }, { r10, r11, r12 }, { r20, r21, r22 } } } }
	end
	return nil
end

local function collectProps(inst)
	local props, attrs = {}, {}
	local class = db:GetClass(inst.ClassName)
	local defaults = class and class.DefaultProperties or {}
	local seen = {}
	while class do
		for name, def in class.Properties do
			if not seen[name] and not SKIP_PROPS[name] and def.Scriptability == "ReadWrite" then
				seen[name] = true
				local ok, value = pcall(function()
					return inst[name]
				end)
				if ok and value ~= nil and (defaults[name] == nil or defaults[name] ~= value) then
					local enc = encode(value)
					if enc ~= nil then
						props[name] = enc
					end
				end
			end
		end
		class = class.Superclass and db:GetClass(class.Superclass)
	end
	local okA, a = pcall(function()
		return inst:GetAttributes()
	end)
	if okA then
		for k, v in a do
			local enc = encode(v)
			if enc ~= nil then
				attrs[k] = if typeof(v) == "string" then { String = v } elseif typeof(v) == "number" then { Float64 = v } elseif typeof(v) == "boolean" then { Bool = v } else enc
			else
				warn(`attribute {inst:GetFullName()}.{k} ({typeof(v)}) not exported`)
			end
		end
	end
	return props, attrs
end

local function writeJson(path, tbl)
	fs.writeFile(path, serde.encode("json", tbl, true) .. "\n")
end

local function scriptSuffix(inst)
	if inst.ClassName == "Script" then
		return ".server.luau"
	elseif inst.ClassName == "LocalScript" then
		return ".client.luau"
	end
	return ".luau"
end

local function scriptMeta(inst)
	local props = {}
	local ok, enabled = pcall(function()
		return inst.Enabled
	end)
	if ok and enabled == false then
		props.Enabled = false
	end
	if inst.ClassName == "Script" then
		local okR, rc = pcall(function()
			return inst.RunContext
		end)
		if okR and rc and rc.Name ~= "Legacy" then
			props.RunContext = { Enum = rc.Value }
		end
	end
	local _, attrs = collectProps(inst)
	local meta = {}
	if next(props) then
		meta.properties = props
	end
	if next(attrs) then
		meta.attributes = attrs
	end
	return if next(meta) then meta else nil
end

local writeChildren

local function writeInstance(inst, dir)
	local name = safeName(inst.Name)
	local base = `{dir}/{name}`

	if isScript(inst) then
		stats.scripts += 1
		local suffix = scriptSuffix(inst)
		local meta = scriptMeta(inst)
		if #inst:GetChildren() == 0 then
			fs.writeFile(base .. suffix, inst.Source)
			if meta then
				writeJson(base .. ".meta.json", meta)
			end
		else
			fs.writeDir(base)
			fs.writeFile(`{base}/init{suffix}`, inst.Source)
			if meta then
				writeJson(`{base}/init.meta.json`, meta)
			end
			writeChildren(inst, base)
		end
	elseif not hasCode(inst) then
		stats.models += 1
		fs.writeFile(base .. ".rbxm", roblox.serializeModel({ inst }))
	else
		stats.dirs += 1
		fs.writeDir(base)
		local props, attrs = collectProps(inst)
		local meta = {}
		if inst.ClassName ~= "Folder" then
			meta.className = inst.ClassName
		end
		if next(props) then
			meta.properties = props
		end
		if next(attrs) then
			meta.attributes = attrs
		end
		if next(meta) then
			writeJson(`{base}/init.meta.json`, meta)
		end
		writeChildren(inst, base)
	end
end

function writeChildren(parent, dir, skip)
	local used = {}
	for _, child in parent:GetChildren() do
		if skip and skip[child.Name] then
			continue
		end
		local key = safeName(child.Name):lower()
		if used[key] then
			warn(`duplicate sibling name "{child:GetFullName()}" — only the first was exported`)
			continue
		end
		used[key] = true
		writeInstance(child, dir)
	end
end

-- main ---------------------------------------------------------------------
local contents = fs.readFile(placePath)
local game = if placePath:match("%.rbxlx$") then roblox.deserializePlace(contents) else roblox.deserializePlace(contents)

if fs.isDir(OUT) then
	fs.removeDir(OUT)
end
fs.writeDir(OUT)

local tree = { ["$className"] = "DataModel" }
for _, svcName in SERVICES do
	local ok, svc = pcall(function()
		return game:GetService(svcName)
	end)
	if not ok or not svc then
		continue
	end
	local dir = `{OUT}/{svcName}`
	fs.writeDir(dir)
	writeChildren(svc, dir, SKIP_CHILD[svcName])
	local node = { ["$path"] = dir }
	if IGNORE_RBXM_SERVICES[svcName] then
		node["$ignoreUnknownInstances"] = true
	end
	local props = collectProps(svc)
	if next(props) then
		node["$properties"] = props
	end
	tree[svcName] = node
end

writeJson("default.project.json", { name = "game1", tree = tree })

print(`unpacked {placePath}: {stats.scripts} scripts, {stats.models} .rbxm models, {stats.dirs} containers`)
for _, w in warnings do
	print("  warn: " .. w)
end
