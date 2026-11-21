-- Cubev4 client-side static reconstruction runtime.
-- This recreates data exported by export_place.luau. It does NOT run any
-- original Script/LocalScript/ModuleScript or reproduce server authority.

local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local CollectionService = game:GetService("CollectionService")
local LocalPlayer = Players.LocalPlayer

local function log(message)
    print("[Cubev4] " .. tostring(message))
end

local function fetch(url)
    local ok, body = pcall(function() return game:HttpGet(url) end)
    if not ok or type(body) ~= "string" or body == "" then
        error("HTTP request failed for " .. url .. ": " .. tostring(body), 0)
    end
    return body
end

local function decodeJson(url)
    local ok, result = pcall(function()
        return HttpService:JSONDecode(fetch(url))
    end)
    if not ok then error("Invalid JSON from " .. url .. ": " .. tostring(result), 0) end
    return result
end

local function enumItem(value)
    local enumType = Enum[value.enumType]
    if not enumType then return nil end
    return enumType[value.name]
end

local function decodeValue(value)
    if type(value) ~= "table" then return value end
    local kind = value.__type

    if kind == "Ref" then
        return { __pendingRef = tostring(value.value) }
    elseif kind == "EnumItem" then
        return enumItem(value)
    elseif kind == "Vector3" then
        return Vector3.new(value.x, value.y, value.z)
    elseif kind == "Vector2" then
        return Vector2.new(value.x, value.y)
    elseif kind == "Vector3int16" then
        return Vector3int16.new(value.x, value.y, value.z)
    elseif kind == "Vector2int16" then
        return Vector2int16.new(value.x, value.y)
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
    elseif kind == "Rect" then
        return Rect.new(value.minX, value.minY, value.maxX, value.maxY)
    elseif kind == "Font" then
        local weight = Enum.FontWeight[value.weight] or Enum.FontWeight.Regular
        local style = Enum.FontStyle[value.style] or Enum.FontStyle.Normal
        return Font.new(value.family, weight, style)
    elseif kind == "Content" then
        if Content and type(Content.fromUri) == "function" then
            return Content.fromUri(value.uri)
        end
        return value.uri
    end
    return value
end

local function removeMarkedChildren(container)
    for _, child in ipairs(container:GetChildren()) do
        local marked = false
        pcall(function() marked = child:GetAttribute("Cubev4Generated") == true end)
        if marked then child:Destroy() end
    end
end

local function getRootTarget(rootName, mainRoot, rootFolders)
    if rootName == "Lighting" then return game:GetService("Lighting") end
    if rootName == "SoundService" then return game:GetService("SoundService") end
    if rootName == "StarterGui" then return LocalPlayer:WaitForChild("PlayerGui") end
    if rootName == "StarterPack" then return LocalPlayer:WaitForChild("Backpack") end

    if not rootFolders[rootName] then
        local folder = Instance.new("Folder")
        folder.Name = rootName
        folder.Parent = mainRoot
        rootFolders[rootName] = folder
    end
    return rootFolders[rootName]
end

local function run(options)
    options = options or {}
    local baseUrl = assert(options.baseUrl, "baseUrl is required"):gsub("/$", "")
    local manifestPath = options.manifestPath or "/data/manifest.json"

    log("Downloading data manifest...")
    local manifest = decodeJson(baseUrl .. manifestPath)
    if manifest.format ~= "cubev4-client-data-v2" then
        error("Unsupported data format. Re-run export_place.luau with Lune 0.11+.", 0)
    end

    local playerGui = LocalPlayer:WaitForChild("PlayerGui")
    local backpack = LocalPlayer:WaitForChild("Backpack")
    removeMarkedChildren(playerGui)
    removeMarkedChildren(backpack)
    removeMarkedChildren(game:GetService("Lighting"))
    removeMarkedChildren(game:GetService("SoundService"))

    local oldRoot = workspace:FindFirstChild("Cubev4_ClientRebuild")
    if oldRoot then oldRoot:Destroy() end
    local mainRoot = Instance.new("Folder")
    mainRoot.Name = "Cubev4_ClientRebuild"
    mainRoot.Parent = workspace

    local objects = {}
    local pendingParents = {}
    local pendingReferences = {}
    local rootFolders = {}
    local created, failedClasses, failedProperties = 0, 0, 0
    local yieldCounter = 0

    for chunkIndex, chunkInfo in ipairs(manifest.chunks or {}) do
        log(string.format("Loading chunk %d/%d: %s", chunkIndex, #manifest.chunks, chunkInfo.file))
        local chunk = decodeJson(baseUrl .. "/data/" .. chunkInfo.file)
        for _, record in ipairs(chunk.instances or {}) do
            local ok, object = pcall(function() return Instance.new(record.class) end)
            if ok and object then
                object.Name = record.name or record.class
                objects[tostring(record.id)] = object
                pendingParents[#pendingParents + 1] = {
                    object = object,
                    parentId = record.parent and tostring(record.parent) or nil,
                    root = record.root or "Other",
                }

                for propertyName, rawValue in pairs(record.properties or {}) do
                    local decodeOk, value = pcall(decodeValue, rawValue)
                    if decodeOk and type(value) == "table" and value.__pendingRef then
                        pendingReferences[#pendingReferences + 1] = {
                            object = object,
                            property = propertyName,
                            refId = value.__pendingRef,
                        }
                    elseif decodeOk and value ~= nil then
                        local assignOk = pcall(function() object[propertyName] = value end)
                        if not assignOk then failedProperties += 1 end
                    else
                        failedProperties += 1
                    end
                end

                for attributeName, rawValue in pairs(record.attributes or {}) do
                    local decodeOk, value = pcall(decodeValue, rawValue)
                    if decodeOk and value ~= nil and not (type(value) == "table" and value.__pendingRef) then
                        pcall(function() object:SetAttribute(attributeName, value) end)
                    end
                end

                for _, tag in ipairs(record.tags or {}) do
                    pcall(function() CollectionService:AddTag(object, tag) end)
                end

                created += 1
            else
                failedClasses += 1
            end

            yieldCounter += 1
            if yieldCounter >= 1500 then
                yieldCounter = 0
                task.wait()
            end
        end
        task.wait()
    end

    log("Restoring parent relationships...")
    for _, item in ipairs(pendingParents) do
        local parent = item.parentId and objects[item.parentId] or nil
        if not parent then
            parent = getRootTarget(item.root, mainRoot, rootFolders)
            pcall(function() item.object:SetAttribute("Cubev4Generated", true) end)
        end
        pcall(function() item.object.Parent = parent end)
    end

    log("Resolving Instance-valued properties...")
    for _, item in ipairs(pendingReferences) do
        local referenced = objects[item.refId]
        if referenced then
            pcall(function() item.object[item.property] = referenced end)
        end
    end

    log(string.format(
        "Finished. Created %d instances; unsupported classes %d; property assignments failed %d; source instances %d.",
        created, failedClasses, failedProperties, manifest.totalInstances or 0
    ))
    log("Static reconstruction only: original scripts, networking, server gameplay, and persistence are not run.")
    return {
        created = created,
        failedClasses = failedClasses,
        failedProperties = failedProperties,
        root = mainRoot,
        objects = objects,
    }
end

return function(options)
    return run(options)
end
