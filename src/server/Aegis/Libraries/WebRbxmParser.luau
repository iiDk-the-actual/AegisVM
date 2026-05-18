--[[
    WebRbxmParser.luau - JSON-encoded rbxm object tree deserializer

    Fetches a JSON-encoded rbxm object tree from the AegisVM convert
    endpoint and reconstructs Roblox Instances from it.  Scripts found
    in the tree are wrapped in a sandboxed AegisVM runner: the original
    source is stored as a "Source" attribute, a template script from the
    WebRbxmParser folder is cloned, and a cloned Aegis module named _aegis
    is parented to the clone so it can require and run the stored source.

    Public API (via module table):

        module:GetObjects(url)     -- fetch + decode, returns { Instance, ... }
        module:LoadAsset(id)       -- sugar: GetObjects("rbxassetid://"..id)
        module:LoadAssetAsync(id)  -- alias for LoadAsset (synchronous)

]]--

local Constants = require(script.Parent.Parent.Constants)
local NewScript  = require(script.Parent.NewScript)

local module = {}

local HttpService = game:GetService("HttpService")
local InsertService = game:GetService("InsertService")

local function decodeKey(class, key)
	if key == "Color3" then
		return "Color"
	elseif key == "Part0Internal" then
		return "Part0"
	elseif key == "Part1Internal" then
		return "Part1"
	end

	return key -- all else
end

local function decodeValue(key, value)
	if type(value) ~= "table" then
		return value
	end

	if value.__ref ~= nil then
		return value  -- resolved in applyPendingRefs()
	end

	if value.R and value.G and value.B then
		if value.R > 1 or value.G > 1 or value.B > 1 then
			return Color3.fromRGB(value.R, value.G, value.B)
		else
			return Color3.new(value.R, value.G, value.B)
		end
	end

	if value.X and value.Y and not value.Z then
		return Vector2.new(value.X, value.Y)
	end

	if value.X and value.Y and value.Z then
		return Vector3.new(value.X, value.Y, value.Z)
	end

	if value.Scale and value.Offset then
		return UDim.new(value.Scale, value.Offset)
	end

	if value.X and value.Y and type(value.X) == "table" and type(value.Y) == "table" then
		return UDim2.new(value.X.Scale, value.X.Offset, value.Y.Scale, value.Y.Offset)
	end

	if value.Position and value.Orientation then
		return CFrame.new(value.Position.X, value.Position.Y, value.Position.Z) *
			CFrame.fromEulerAnglesXYZ(
				math.rad(value.Orientation.X),
				math.rad(value.Orientation.Y),
				math.rad(value.Orientation.Z)
			)
	end

	if value.Name and value.Number and value.Color then -- brickcolor
		return BrickColor.new(value.Name)
	end

	if type(value) == "number" and key.Name == "BrickColor" then -- fallback/xml
		return BrickColor.new(value)
	end

	-- Rect2D: { Min = { X, Y }, Max = { X, Y } }  (e.g. SliceCenter)
	if value.Min and value.Max
		and type(value.Min) == "table" and type(value.Max) == "table"
		and value.Min.X ~= nil and value.Min.Y ~= nil
		and value.Max.X ~= nil and value.Max.Y ~= nil
	then
		return Rect.new(value.Min.X, value.Min.Y, value.Max.X, value.Max.Y)
	end

	-- NumberRange: { Min, Max }  (e.g. PlaybackRegion, LoopRegion)
	-- Must come after Rect2D check since both have Min/Max.
	if value.Min ~= nil and value.Max ~= nil
		and type(value.Min) == "number" and type(value.Max) == "number"
	then
		return NumberRange.new(value.Min, value.Max)
	end

	-- NumberSequence: array of { Time, Value, Envelope } keypoints
	if type(value[1]) == "table" and value[1].Time ~= nil and value[1].Value ~= nil then
		local keypoints = {}
		for _, kp in ipairs(value) do
			table.insert(keypoints, NumberSequenceKeypoint.new(
				kp.Time,
				kp.Value,
				kp.Envelope or 0
				))
		end
		return NumberSequence.new(keypoints)
	end

	if value.EnumType and value.Name then
		local success, enum = pcall(function()
			return Enum[value.EnumType][value.Name]
		end)
		if success then
			return enum
		end
	end

	return value
end

local function getProperties(obj)
	local props = {}
	for key, value in pairs(obj) do
		if key ~= "ClassName"     -- done on create
			and key ~= "Children" -- js-side for child tracking
			and key ~= "DefinesCapabilities" -- No idea
			and key ~= "Tags" -- unknown
			and key ~= "AttributesSerialize" -- serialized later
			and key ~= "_id"      -- JS-side UUID
			and key ~= "_rbxId"   -- JS-side file-internal id
			and key ~= "_childInstances" -- JS unioning
			and key ~= "_tags" -- JS unioning
			and key ~= "Source" -- Sandboxing
		then
			local properKey = decodeKey(obj.ClassName, key)
			props[properKey] = decodeValue(properKey, value)
		end
	end
	return props
end

local function decodeEscapedString(str)
	local bytes = {}

	for hex in str:gmatch("\\u(%x%x%x%x)") do
		local code = tonumber(hex, 16)

		if code <= 0xFF then
			table.insert(bytes, string.char(code))
		else
			local hi = math.floor(code / 256)
			local lo = code % 256
			table.insert(bytes, string.char(lo))
			table.insert(bytes, string.char(hi))
		end
	end

	return table.concat(bytes)
end

local function readInt32LE(data, i)
	local b1, b2, b3, b4 = data:byte(i, i+3)
	return b1 + b2*256 + b3*65536 + b4*16777216, i + 4
end

local function readDoubleLE(data, i)
	local bytes = {data:byte(i, i+7)}

	local sign = (bytes[8] > 127) and -1 or 1
	local exponent = ((bytes[8] % 128) * 16 + math.floor(bytes[7] / 16))
	local mantissa = (bytes[7] % 16)

	for j = 6, 1, -1 do
		mantissa = mantissa * 256 + bytes[j]
	end

	if exponent == 0 then
		return 0, i + 8
	end

	local value = sign * (1 + mantissa / 2^52) * 2^(exponent - 1023)
	return value, i + 8
end

local function parseAttributes(blob)
	local data = decodeEscapedString(blob)
	local i = 1
	local result = {}

	while i <= #data do
		local nameLen
		nameLen, i = readInt32LE(data, i)

		local name = data:sub(i, i + nameLen - 1)
		i = i + nameLen

		local attrType = data:byte(i)
		i = i + 1

		local value

		if attrType == 3 then
			value = data:byte(i) ~= 0
			i = i + 1

		elseif attrType == 6 then
			value, i = readDoubleLE(data, i)

		else
			warn("Unknown attribute type:", attrType)
			break
		end

		result[name] = value
	end

	return result
end

local function handleMeshPart(objectData, parent)
	local meshPart
	local s, f = pcall(function()
		meshPart = InsertService:CreateMeshPartAsync(
			objectData.MeshId or "0",
			objectData.CollisionFidelity or Enum.CollisionFidelity.Box,
			objectData.RenderFidelity or Enum.RenderFidelity.Automatic
		)
		meshPart.Parent = parent
	end)
	if not s then meshPart = Instance.new("MeshPart", parent) end
	return meshPart
end

 local reconstructCSG  -- forward declaration

  local CSG_OP_CLASSES = {
      UnionOperation    = true,
      IntersectOperation = true,
      NegateOperation   = true,
  }

  local function isNegativePart(objData)
      if objData.ClassName == "NegateOperation" then return true end
      if type(objData._tags) == "table" then
          for _, tag in ipairs(objData._tags) do
              if tag == "rbxNegated" then return true end
          end
      end
      return false
  end

  -- Corrects the mesh pivot to the bounding-box center so that
  -- setting CFrame later positions the union where it should be.
  local function centerCSGPivot(union)
      local RS = game:GetService("ReplicatedStorage")
      local ok, err = pcall(function()
          local tmp = Instance.new("Model")
          union.Parent = tmp
          tmp.Parent = RS
          local boxCF = tmp:GetBoundingBox()
          tmp:Destroy()

          local anchor = Instance.new("Part")
          anchor.Size       = Vector3.new(0.001, 0.001, 0.001)
          anchor.CFrame     = boxCF
          anchor.Anchored   = union.Anchored
          anchor.Transparency = 1
          anchor.CanCollide = false
          anchor.Parent     = RS

          local recentered
          pcall(function()
              recentered = anchor:UnionAsync({union},
                  Enum.CollisionFidelity.Default, Enum.RenderFidelity.Automatic)
          end)
          anchor:Destroy()

          if recentered then
              pcall(function() union:SubstituteGeometry(recentered) end)
              recentered:Destroy()
          end
          union.Parent = RS
      end)
      if not ok then warn("[CSG] centerCSGPivot:", err) end
  end

-- First pass
local function recursiveDecode(objectData, parent, ctx)
	local object

	local s,f = pcall(function()
		-- CSG reconstruction path
		if CSG_OP_CLASSES[objectData.ClassName] and objectData._childInstances then
			object = reconstructCSG(objectData, ctx)
			if object then
				object.Parent = parent
			end
		end

		-- Normal creation path (also fallback if CSG reconstruction failed)
		if not object then
			if objectData.ClassName == "MeshPart" then
				object = handleMeshPart(objectData, parent)
			elseif objectData.ClassName == "Script"
				or objectData.ClassName == "LocalScript"
				or objectData.ClassName == "ModuleScript"
			then
				-- When REPLICATE_SCRIPTS is enabled and an owner is known,
				-- create a server Script instead of a LocalScript so that
				-- CLIENT_COMMUNICATION can replicate client APIs to the owner.
				local scriptType = objectData.ClassName
				if Constants.REPLICATE_SCRIPTS
					and scriptType == "LocalScript"
					and ctx.ownerUserId ~= nil
				then
					scriptType = "Script"
				end
				object = NewScript.new({
					source      = objectData.Source or "",
					parent      = parent,
					type        = scriptType,
					ownerUserId = ctx.ownerUserId,
				})
				-- ... (rest of script setup unchanged)
			else
				object = Instance.new(objectData.ClassName, parent or nil)
			end
		end
	end)
	if not s or object == nil then
		object = Instance.new("Tween", parent or nil)
	end

	local s,f = pcall(function()
		if objectData._id then
			ctx.instanceMap[objectData._id] = object
		end

		for _, child in pairs(objectData.Children) do
			recursiveDecode(child, object, ctx)
		end

		-- Attributes
		if objectData.AttributesSerialize then
			local attributes = parseAttributes(objectData.AttributesSerialize)
			for key, value in pairs(attributes) do
				object:SetAttribute(key, value)
			end
		end

		-- Properties
		for key, value in pairs(getProperties(objectData)) do
			if type(value) == "table" and value.__ref ~= nil then
				-- Defer: we may not have created the target instance yet.
				table.insert(ctx.pendingRefs, {
					instance = object,
					key      = key,
					targetId = value.__ref,
				})
			else
				local s, f = pcall(function()
					object[key] = value
				end)
				if not s then
					warn(object:GetFullName() .. " could not set property " .. key .. " " .. f)
					if key == "Color" then
						local s2, f2 = pcall(function()
							object["Color3"] = value
						end)
						if not s2 then
							warn(object:GetFullName() .. " could not set property Color3 " .. f2)
						end
					end
				end
			end
		end
	end)
	if not s then warn(f) end

	return object
end

reconstructCSG = function(objectData, ctx)
	local isIntersect = objectData.ClassName == "IntersectOperation"
	local children    = objectData._childInstances
	if not children or #children == 0 then return nil end

	local RS = game:GetService("ReplicatedStorage")
	local holder = Instance.new("Folder")
	holder.Parent = RS

	local posParts, negParts = {}, {}
	for _, childData in ipairs(children) do
		-- recursiveDecode handles nested CSG ops automatically
		local inst = recursiveDecode(childData, holder, ctx)
		if inst and inst:IsA("BasePart") then
			if isNegativePart(childData) then
				table.insert(negParts, inst)
			else
				table.insert(posParts, inst)
			end
		end
	end

	if #posParts == 0 then
		holder:Destroy()
		return nil
	end

	local base   = table.remove(posParts, 1)
	local result = nil

	local ok, err = pcall(function()
		if isIntersect then
			if #posParts > 0 then
				result = base:IntersectAsync(posParts,
					Enum.CollisionFidelity.Default, Enum.RenderFidelity.Automatic)
				result.Parent = RS
				local final = base:IntersectAsync({result},
					Enum.CollisionFidelity.Default, Enum.RenderFidelity.Automatic)
				result:Destroy()
				result = final
			else
				result = base:Clone()
			end
		else
			-- Union (also the reconstruction path for NegateOperation shapes)
			if #posParts > 0 then
				result = base:UnionAsync(posParts,
					Enum.CollisionFidelity.Default, Enum.RenderFidelity.Automatic)
				result.Parent = RS
			else
				result = base:Clone()
			end
			if result and #negParts > 0 then
				local sub = result:SubtractAsync(negParts,
					Enum.CollisionFidelity.Default, Enum.RenderFidelity.Automatic)
				if sub then
					result:Destroy()
					result = sub
				end
			end
		end
	end)

	-- Destroy the holder (cleans up all input parts still parented there)
	holder:Destroy()

	if not ok or not result then
		warn("[CSG] Reconstruction failed:", tostring(err))
		if result and result.Parent then result:Destroy() end
		return nil
	end

	result.Parent = RS
	centerCSGPivot(result)
	return result
end

-- Second pass: resolve deferred Reference properties
local function applyPendingRefs(ctx)
	for _, entry in ipairs(ctx.pendingRefs) do
		local target = ctx.instanceMap[entry.targetId]
		if target then
			local s, f = pcall(function()
				entry.instance[entry.key] = target
			end)
			if not s then
				warn(entry.instance:GetFullName()
					.. " could not set reference property "
					.. entry.key .. " > "
					.. target:GetFullName() .. " | " .. f)
			end
		else
			warn("Could not resolve reference for property '"
				.. entry.key .. "' on "
				.. entry.instance:GetFullName()
				.. " (target _id: " .. tostring(entry.targetId) .. ")")
		end
	end
end

-- owner is an optional Player instance forwarded from the calling environment.
-- Used by REPLICATE_SCRIPTS to inject the owner into sub-script sandboxes.
function module:GetObjects(url, owner)
	if Constants.VERBOSITY > Constants.VERBOSITY_SUPPRESS then
		warn("Fetching rbxm asset " .. tostring(url) .. ".")
	end
	local rbxmData = HttpService:GetAsync(
		Constants.CONVERT_BASE_URL .. HttpService:UrlEncode(url)
	)
	local data = HttpService:JSONDecode(rbxmData)

	-- Resolve the owner's UserId safely (owner may be nil or already gone).
	local ownerUserId = nil
	if owner ~= nil then
		local ok, uid = pcall(function() return owner.UserId end)
		if ok and uid then ownerUserId = uid end
	end

	local objects = {}
	local ctx = {
		scripts     = {},
		instanceMap = {},    -- _id (uuid string) -> Roblox Instance
		pendingRefs = {},    -- deferred { instance, key, targetId } entries
		ownerUserId = ownerUserId,  -- forwarded to NewScript for REPLICATE_SCRIPTS
	}

	for _, objectData in pairs(data) do
		table.insert(objects, recursiveDecode(objectData, nil, ctx))
	end

	applyPendingRefs(ctx)

	for _, scriptObj in ipairs(ctx.scripts) do
		if scriptObj:IsA("LuaSourceContainer") and not scriptObj:IsA("ModuleScript") then
			scriptObj.Enabled = scriptObj:GetAttribute("scriptIsEnabled")
		end
	end

	return objects
end

function module:LoadAsset(id)
	return module:GetObjects("rbxassetid://"..id)
end

function module:LoadAssetAsync(id) -- No
	return module:LoadAsset(id)
end

return module
