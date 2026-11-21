-- Cubev4 local reconstruction runtime (prototype)
-- Builds serialised Instances locally. Script and remote classes are omitted by the converter.
-- This does NOT recreate server authority, networking, persistence, or original gameplay code.

local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local LocalPlayer = Players.LocalPlayer

local Runtime = {}
local CONFIG = {
    YieldEvery = 250,
    ClearPrevious = true,
    RootTargets = {
        Lighting = function() return game:GetService("Lighting") end,
        SoundService = function() return game:GetService("SoundService") end,
        StarterGui = function()
            return LocalPlayer:WaitForChild("PlayerGui")
        end,
        StarterPack = function()
            return LocalPlayer:WaitForChild("Backpack")
        end,
    },
}

local function log(message)
    print("[Cubev4] " .. tostring(message))
end

local function warnLog(message)
    warn("[Cubev4] " .. tostring(message))
end

local function fetch(url)
    local ok, result = pcall(function()
        return game:HttpGet(url)
    end)
    if not ok then
        error("HTTP request failed for " .. url .. ": " .. tostring(result), 0)
    end
    return result
end

local function decodeJson(url)
    local body = fetch(url)
    local ok, value = pcall(function()
        return HttpService:JSONDecode(body)
    end)
    if not ok then
        error("Invalid JSON from " .. url .. ": " .. tostring(value), 0)
    end
    return value
end

local ENUM_PROPERTY_MAP = {
    Material = "Material", Shape = "PartType", FormFactor = "FormFactor",
    TopSurface = "SurfaceType", BottomSurface = "SurfaceType",
    LeftSurface = "SurfaceType", RightSurface = "SurfaceType",
    FrontSurface = "SurfaceType", BackSurface = "SurfaceType",
    Font = "Font", TextXAlignment = "TextXAlignment", TextYAlignment = "TextYAlignment",
    TextTruncate = "TextTruncate", TextDirection = "TextDirection",
    ScaleType = "ScaleType", ResampleMode = "ResamplerMode",
    ZIndexBehavior = "ZIndexBehavior", AutomaticSize = "AutomaticSize",
    HorizontalAlignment = "HorizontalAlignment", VerticalAlignment = "VerticalAlignment",
    SortOrder = "SortOrder", FillDirection = "FillDirection",
    EasingStyle = "EasingStyle", EasingDirection = "EasingDirection",
    PlaybackState = "PlaybackState", RigType = "HumanoidRigType",
    AnimationPriority = "AnimationPriority", NormalId = "NormalId",
    FontSize = "FontSize", BorderMode = "BorderMode",
    ActuatorType = "ActuatorType", RotationType = "RotationType",
    CameraType = "CameraType", CameraMode = "CameraMode",
    DisplayDistanceType = "HumanoidDisplayDistanceType",
    NameOcclusion = "NameOcclusion", HealthDisplayType = "HumanoidHealthDisplayType",
    ProximityPromptStyle = "ProximityPromptStyle", StreamingMode = "ModelStreamingMode",
}

local function enumFromToken(propertyName, value)
    local enumName = ENUM_PROPERTY_MAP[propertyName]
    if not enumName then return nil end
    local enumType = Enum[enumName]
    if not enumType then return nil end
    local ok, items = pcall(function() return enumType:GetEnumItems() end)
    if not ok then return nil end
    for _, item in ipairs(items) do
        if item.Value == tonumber(value) then
            return item
        end
    end
    return nil
end

local function decodeValue(value, propertyName)
    if type(value) ~= "table" then
        return value
    end

    local kind = value.__type
    if kind == "Ref" then
        return { __pendingRef = tostring(value.value) }
    elseif kind == "Vector3" then
        return Vector3.new(value.x, value.y, value.z)
    elseif kind == "Vector2" then
        return Vector2.new(value.x, value.y)
    elseif kind == "Color3" then
        return Color3.new(value.r, value.g, value.b)
    elseif kind == "CFrame" then
        return CFrame.new(table.unpack(value.components))
    elseif kind == "UDim" then
        return UDim.new(value.scale, value.offset)
    elseif kind == "UDim2" then
        return UDim2.new(value.xScale, value.xOffset, value.yScale, value.yOffset)
    elseif kind == "BrickColor" then
        return BrickColor.new(value.number)
    elseif kind == "NumberRange" then
        return NumberRange.new(value.min, value.max)
    elseif kind == "NumberSequence" then
        local points = {}
        for _, point in ipairs(value.keypoints or {}) do
            points[#points + 1] = NumberSequenceKeypoint.new(point.time, point.value, point.envelope or 0)
        end
        return NumberSequence.new(points)
    elseif kind == "ColorSequence" then
        local points = {}
        for _, point in ipairs(value.keypoints or {}) do
            points[#points + 1] = ColorSequenceKeypoint.new(point.time, Color3.new(point.r, point.g, point.b))
        end
        return ColorSequence.new(points)
    elseif kind == "PhysicalProperties" then
        return PhysicalProperties.new(value.density, value.friction, value.elasticity, value.frictionWeight, value.elasticityWeight)
    elseif kind == "Token" then
        return enumFromToken(propertyName, value.value)
    elseif kind == "Content" then
        return value.value
    elseif kind == "Rect" then
        return Rect.new(value.minX, value.minY, value.maxX, value.maxY)
    end

    return value
end

local function targetForRoot(rootName, rootFolders)
    local provider = CONFIG.RootTargets[rootName]
    if provider then
        local ok, target = pcall(provider)
        if ok and target then return target end
    end

    if not rootFolders[rootName] then
        local folder = Instance.new("Folder")
        folder.Name = "Cubev4_" .. tostring(rootName)
        folder.Parent = workspace
        rootFolders[rootName] = folder
    end
    return rootFolders[rootName]
end

local function clearPrevious()
    if not CONFIG.ClearPrevious then return end
    local containers = { workspace }
    local okGui, playerGui = pcall(function() return LocalPlayer:FindFirstChildOfClass("PlayerGui") end)
    if okGui and playerGui then containers[#containers + 1] = playerGui end
    local okPack, backpack = pcall(function() return LocalPlayer:FindFirstChildOfClass("Backpack") end)
    if okPack and backpack then containers[#containers + 1] = backpack end
    containers[#containers + 1] = game:GetService("Lighting")
    containers[#containers + 1] = game:GetService("SoundService")
    for _, container in ipairs(containers) do
        for _, child in ipairs(container:GetChildren()) do
            local marked = false
            pcall(function() marked = child:GetAttribute("Cubev4Generated") == true end)
            if marked or child.Name:sub(1, 7) == "Cubev4_" then
                child:Destroy()
            end
        end
    end
end

function Runtime.run(options)
    options = options or {}
    local baseUrl = assert(options.baseUrl, "baseUrl is required")
    local manifestPath = options.manifestPath or "/data/manifest.json"
    local base = baseUrl:gsub("/$", "")

    log("Fetching data manifest...")
    local manifest = decodeJson(base .. manifestPath)
    if manifest.format ~= "cubev4-client-data-v1" then
        error("Unsupported data manifest format. Re-run convert_rbxlx.py.", 0)
    end

    clearPrevious()
    local objects = {}
    local pendingProperties = {}
    local pendingParents = {}
    local rootFolders = {}
    local created = 0
    local failed = 0

    for chunkIndex, chunkInfo in ipairs(manifest.chunks or {}) do
        log(string.format("Loading data chunk %d/%d: %s", chunkIndex, #manifest.chunks, chunkInfo.file))
        local chunk = decodeJson(base .. "/data/" .. chunkInfo.file)
        for _, record in ipairs(chunk.instances or {}) do
            local ok, objectOrError = pcall(function()
                return Instance.new(record.class)
            end)

            if ok and objectOrError then
                local object = objectOrError
                object.Name = record.name or record.class
                objects[tostring(record.id)] = object
                pendingParents[#pendingParents + 1] = {
                    object = object,
                    parentId = record.parent and tostring(record.parent) or nil,
                    root = record.root,
                }

                for propertyName, rawValue in pairs(record.properties or {}) do
                    if propertyName ~= "Name" and propertyName ~= "Parent" then
                        local decodeOk, value = pcall(decodeValue, rawValue, propertyName)
                        if decodeOk and type(value) == "table" and value.__pendingRef then
                            pendingProperties[#pendingProperties + 1] = {
                                object = object,
                                property = propertyName,
                                refId = value.__pendingRef,
                            }
                        elseif decodeOk and value ~= nil then
                            pcall(function()
                                object[propertyName] = value
                            end)
                        end
                    end
                end
                created = created + 1
            else
                failed = failed + 1
            end

            if created > 0 and created % CONFIG.YieldEvery == 0 then
                task.wait()
            end
        end
        task.wait()
    end

    log("Applying parent relationships...")
    for _, item in ipairs(pendingParents) do
        local parent = item.parentId and objects[item.parentId] or nil
        if not parent then
            parent = targetForRoot(item.root or "Other", rootFolders)
            pcall(function() item.object:SetAttribute("Cubev4Generated", true) end)
        end
        pcall(function() item.object.Parent = parent end)
    end

    log("Resolving object references...")
    for _, item in ipairs(pendingProperties) do
        local referenced = objects[item.refId]
        if referenced then
            pcall(function() item.object[item.property] = referenced end)
        end
    end

    log(string.format("Reconstruction finished. Created: %d | Failed classes: %d | Input instances: %d", created, failed, manifest.totalInstances or 0))
    log("Reminder: scripts, remotes, server logic, and unsupported/read-only properties are not recreated.")
    return {
        created = created,
        failed = failed,
        objects = objects,
        roots = rootFolders,
    }
end

return function(options)
    return Runtime.run(options)
end
